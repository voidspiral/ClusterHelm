---
name: mpi-monitor
description: >-
  Wrap MPI or other task processes with mpi-monitor on the Slave gateway.
  Use when the user asks to sample rank PID CPU, RSS, or IO, wrap mpirun,
  collect process timeseries JSONL, or plot per-process PNG charts.
  Deployed to Slave only — not used on Master workspace.
compatibility: opencode
metadata:
  role: slave
  deploy: deploy-slave.sh
---

# MPI Monitor (Slave gateway)

This skill is **deployed to the Slave gateway** (e.g. cn1) via **`deploy-slave.sh`**
(skills under `slave/.opencode/skills/`). It does **not** apply on the Master
workspace.

The CLI is the standalone **`mpi-monitor`** package. Master deploys it to the
gateway with **`./scripts/deploy/deploy-mpi-monitor.sh cn1`** (copies to
`$remote_project/vendor/mpi-monitor` and installs into a local `.venv`;
PEP 668 hosts must not use system `pip`). Optional PNG: `MPI_MONITOR_PLOT=1`.
**Do not install on cn2–cnN.** `wrap` SSHes an
inline Python payload so remote nodes need `python3` and `/proc` only.
`deploy-slave.sh` only syncs this skill text — it does not install the package.

`mpi-monitor wrap` is a **gateway-local sidecar**, not a `workflow_runner.py`
job and not `run-slave.sh --command` fan-out.

**Hard gate (before preflight or wrap):** probe the CLI on this gateway with a
**bash argv array** (or `scripts/probe-cli.sh`) then `"${argv[@]}" probe`.
If it is not installed, mark the job **failed** and **stop**. Do not preflight,
wrap, `pip install`, SSH compute nodes, or invent series.

**Never** store a multi-word invocation in one string and quote it as a
pathname (`MPI_MON="env PYTHONPATH=… python3 -m mpi_monitor"; "$MPI_MON"` →
`No such file or directory`).

## When to use

- User wants process-level CPU / RSS / IO for MPI ranks or a matched binary
- User asks to **wrap** `mpirun` / `mpiexec` with a sidecar collector
- User asks for per-PID JSONL timeseries or per-process PNG charts
- Short HPC jobs (NPB class S, sub-second) that need `--interval` &lt; 1s
- **Not** for node RAM/swap/OOM (use `memory-monitor`) or host heartbeat (use `nodestatus`)

## Deterministic fast path

Once this skill is selected, the monitoring design decision is already made.
Follow this path without exploratory analysis:

1. Do not debate whether to use `mpi-monitor` or replace it with a custom
   sampler. Use one gateway-local `wrap`.
2. Treat this skill and [reference.md](reference.md) as the installed package
   contract. **Do not inspect the installed package source** to reconfirm CLI
   syntax, process discovery, stdout/stderr inheritance, paths, or JSONL fields.
3. Resolve the CLI argv, run `probe`, consume the persisted nodestatus-first
   preflight, and derive the exact `--hosts` intersection.
4. **Generate fresh job-local orchestration and post-processing scripts** when
   the task requests custom CSV columns, combined plots, raw output, summaries,
   or base64. Regeneration is intentional. Generate each script once from the
   requested output contract; do not reconsider the monitoring architecture.
5. Capture the wrapped program's complete output by redirecting `wrap` stdout
   and stderr. The wrapped command inherits those file descriptors; collector
   diagnostics do not replace the program output.
6. Run one wrap, one post-processing pass, and one report-finalization pass.
   After success, inspect only `meta.json`, `series/`, `charts/`, and the
   generated job artifacts. Do not reopen package source.
7. For large binary artifacts, write `plot_base64_png` to the job JSON only.
   Put its path, byte size, and base64 length in markdown; never spend a model
   turn debating whether to inline the base64.

Expected happy-path sequence:

```text
probe → persisted preflight → generate scripts once → wrap once
      → post-process once → update partition_report once → stop
```

Only a real non-zero/usage failure may enter diagnosis, with the existing
one-retry limit. Commentary and extra validation are not separate steps.

## Deterministic exception handling

**Never rerun a successful wrapped command** because collection, plotting,
base64 encoding, or report finalization failed. Preserve completed stages and
retry only the failed stage once when the table allows it.

| Stage / reason code | Terminal status | Required action | Retry |
|---|---|---|---|
| CLI gate / `hard_gate_failed` | failed | Write a failed report and stop before preflight or SSH. | Never |
| Preflight / `insufficient_hosts` | failed | Name reachable, excluded, and missing hosts; do not reduce the requested node count unless the task explicitly permits fallback. Do not wrap. | Never inside this job |
| Wrap / `wrapped_command_failed` | failed | Preserve complete stdout/stderr and `meta.json` when present. Report the command exit code separately from collector errors. | Once only for a proven transient launcher/SSH failure, or a usage error proven to occur before the command started; never retry an application/benchmark non-zero exit |
| Collection / `collection_incomplete` | partial | The command succeeded, but `collect_errors` is non-empty or expected host/PID series are missing. Preserve raw output and available JSONL; identify every missing host/PID. | Do not rerun the command; retry only a supported fetch/collection-finalization operation, otherwise report partial |
| Post-process / `postprocess_failed` | partial | Keep raw output, `meta.json`, and JSONL authoritative. Report which CSV/plot/base64 artifact failed. | Regenerate and rerun the post-processing script once; never rerun wrap |
| Report / `report_finalize_failed` | partial if command result exists, otherwise failed | Rebuild the report from existing artifacts and retain paths to all preserved files. | Rerun finalization once; never rerun wrap or post-processing that already succeeded |

Every exception report or incident sidecar must include `stage`, `reason_code`,
`retry_allowed`, `attempt`, `message`, and `preserved_artifacts`. Status rules:

- `done`: wrapped command succeeded and every required monitoring/report
  artifact exists. An explicitly optional PNG may be absent with a note.
- `partial`: wrapped command succeeded, but required collection, post-processing,
  or reporting is incomplete.
- `failed`: the gate/preflight prevented execution, or the wrapped application
  itself failed.

If the remaining deadline cannot cover the allowed retry, skip it and report
the preserved result immediately. A retry must reuse the same resolved hosts,
command, run directory, and generated script unless that exact value caused
the failure.

## Commands

Gateway `$remote_project` is `/home/cn1/agents` (`master.conf`). Put run output
under the job dir when `AGENT_JOB_DIR` is set.

### CLI hard gate (mandatory, first)

Installed means any one of: PATH `mpi-monitor`, the gateway venv binary, or
`import mpi_monitor` via vendor `PYTHONPATH` / system site-packages.
Missing matplotlib is **not** a failure (PNG is optional).
Do **not** use `"${argv[@]}" --help` or `wrap --help` as the hard gate.

Prefer the packaged gate if the vendor tree has it:

```bash
VENDOR="${REMOTE_PROJECT:-/home/cn1/agents}/vendor/mpi-monitor"
if [[ -x "$VENDOR/scripts/probe-cli.sh" ]]; then
  MPI_MONITOR_VENDOR="$VENDOR" bash "$VENDOR/scripts/probe-cli.sh" || exit 2
fi
```

Otherwise resolve **argv as an array**, then `probe`:

```bash
VENDOR="${REMOTE_PROJECT:-/home/cn1/agents}/vendor/mpi-monitor"
VENV_BIN="$VENDOR/.venv/bin/mpi-monitor"
argv=()
if command -v mpi-monitor >/dev/null 2>&1; then
  argv=("$(command -v mpi-monitor)")
elif [[ -x "$VENV_BIN" ]]; then
  argv=("$VENV_BIN")
elif PYTHONPATH="$VENDOR/src${PYTHONPATH:+:$PYTHONPATH}" python3 -c "import mpi_monitor" >/dev/null 2>&1; then
  argv=(env "PYTHONPATH=$VENDOR/src${PYTHONPATH:+:$PYTHONPATH}" python3 -m mpi_monitor)
elif python3 -c "import mpi_monitor" >/dev/null 2>&1; then
  argv=(python3 -m mpi_monitor)
else
  echo "mpi-monitor CLI is not installed on this gateway" >&2
  exit 2
fi
"${argv[@]}" probe >/dev/null || exit 2
OUT="${AGENT_JOB_DIR:-/home/cn1/agents/var/agent-jobs}/mpi-monitor"
mkdir -p "$OUT"
```

On `exit 2`: write the failed `partition_report` below and terminate. Do not
continue the job flow.

Job JSON is a **flat sibling file**, not a nested directory. Print it with:

```bash
"${argv[@]}" job-json
# {AGENT_JOB_DIR}/{AGENT_JOB_ID}.json
# never {AGENT_JOB_DIR}/{id}/{id}.json
```

### Happy path — wrap (required `--hosts`)

`--hosts` is **required**. `--match` is a substring of the **rank executable**
(`/proc/<pid>/comm` or argv0; shebang scripts also match argv1). It is **not**
a search of later argv. Default `--interval` is `1.0`; short jobs should pass
`0.1` or `0.05`. Exit status equals the wrapped command.

```bash
# HOSTS = reachable ∩ owned partition ∩ the MPI host list from the task
"${argv[@]}" wrap \
  --hosts cn1,cn2,cn3 \
  --match is.S.x \
  --output-dir "$OUT" \
  --interval 0.1 \
  -- \
  mpirun -np 2 -ppn 1 -hosts cn1,cn2 -wdir /tmp /path/to/is.S.x
```

Local short hostname and `localhost` collect in-process; other names use SSH
(`--ssh-user`, `--ssh-identity` if needed). Remote collectors **detach**
(`setsid` in a subshell, not `nohup`) and write under
`/tmp/mpi-monitor/{run_id}/{host}` then `wrap` fetches JSONL back.

Single-node / local ranks: `--hosts "$(hostname -s)"`.

### Debug only — collect / plot / remote-cmd

Do **not** use these as the partition happy path.

```bash
"${argv[@]}" collect --match BIN --output-dir DIR --stop-file FILE --host HOST
"${argv[@]}" plot --run-dir DIR
"${argv[@]}" remote-cmd -- collect --match BIN --output-dir DIR --stop-file FILE --host HOST
```

`remote-cmd` prints `echo <b64> | base64 -d | python3 - …` for nodes without
the package. `wrap` already does this.

## Reading output

Run directory:

```text
{output-dir}/{run_id}/
  meta.json
  series/{host}_pid{pid}.jsonl
  charts/{run_id}_{host}_pid{pid}_{cpu|rss|io_read|io_write}.png
```

### `meta.json`

| Field | Meaning |
|-------|---------|
| `run_id` | `{UTC}T{HMS}Z-{wrap-pid}` |
| `hosts` | `--hosts` list |
| `match` | executable substring (comm / argv0) |
| `command` | wrapped argv |
| `interval` | sample period (seconds) |
| `started_at` / `ended_at` | ISO-8601 UTC |
| `exit_code` | wrapped command status |
| `collect_errors` | `{host: error}` (empty object if none) |

### JSONL sample (one object per line)

| Field | Type | Meaning |
|-------|------|---------|
| `ts` | float | Unix epoch seconds |
| `host` | string | short hostname |
| `pid` | int | sampled task PID |
| `cpu_pct` | float | `/proc/<pid>/stat` utime+stime vs wall (CLK_TCK) |
| `rss_mb` | float | `VmRSS` |
| `io_read_bps` / `io_write_bps` | float | `/proc/<pid>/io` deltas |
| `rank` | int | optional; `PMIX_RANK` / `OMPI_COMM_WORLD_RANK` / `PMI_RANK` |

Launchers are never sampled: `mpirun`, `mpiexec`, `orted`, `orterun`, `prted`,
`prterun`, `sshd`, `ssh`, `hydra_pmi_proxy`, and the collector PID.
`--match` in later argv (`wrap --match is.S.x`, `mpirun … is.S.x`) does **not**
select that process.

If matplotlib is missing, JSONL is still written; PNG is skipped with a
stderr warning. Wrap still returns the command's exit code.

## Reporting to user

If the CLI hard gate fails, report **failed** and stop (no wrap output):

```markdown
# MPI process monitor: test
- Job: mpi-monitor (`job-…`)
- Status: **failed**
- Reason: `mpi-monitor` not installed on gateway cn1
- Action taken: aborted before preflight/wrap
- Remediation: install CLI on cn1 only (`pip install -e /path/to/mpi-monitor`); do not install on cn2–cnN
```

After a successful wrap, synthesize `partition_report` from `meta.json` plus
series/chart counts. Do not dump raw JSONL.

```markdown
# MPI process monitor: test
- Job: mpi-monitor (`job-…`)
- Status: done
- Wrap exit: 0 (wrapped command)
- Run: `20260825T020607Z-59020`
- Hosts: cn1, cn2, cn3 (reachable 3/3)
- Match: `is.S.x` @ interval 0.1s
- Series: 2 files under `…/series/`
- Charts: 8 PNG (cpu/rss/io_read/io_write × pid) or skipped (no matplotlib)

| Host | pid | rank | samples | notes |
|------|-----|------|---------|-------|
| cn1  | 59020 | 0 | 120 | |
| cn2  | 4412 | 1 | 118 | |

**Collect errors:** none
```

Name excluded/unreachable hosts in prose — they were not in `--hosts`.

## Job flow

1. **CLI hard gate** on this gateway (argv array + `probe`, or `probe-cli.sh`).
   Missing install → failed report, **stop**. No preflight, wrap, `pip install`,
   or `--help`. Do not quote a multi-word CLI as one pathname.
2. Preflight the owned partition (nodestatus → ping/SSH fallback). Do not wrap
   on excluded or unreachable nodes.
3. Build `--hosts` from reachable hosts ∩ the MPI host list in the task.
   Never invent hostnames.
4. On **this gateway**, run **one** `"${argv[@]}" wrap … -- CMD`.
   Non-zero wrap writes `$CLUSTERHELM_INCIDENT_PATH` (job sidecar) for Master.
5. Read `{output-dir}/{run_id}/meta.json`; list `series/` and `charts/`.
   Job JSON path: `"${argv[@]}" job-json` (flat file, not nested).
6. Write one `partition_report`. Wrap's exit code is the MPI/command status.
   After a non-zero wrap: at most **one** targeted retry, then print the
   report contract. Do not loop unbounded Hydra/SSH diagnosis.

Low-level debug (not the happy path): `collect` with an explicit `--stop-file`,
or `plot --run-dir` after JSONL exists.

## Forbidden

- Continuing after a failed CLI hard gate (no wrap, no pip, no SSH, no fake series)
- Quoting a multi-word CLI as one pathname (`"$MPI_MON"` / `$MPI_MON` when it
  contains spaces) — always expand an argv array
- Using `python3 -m mpi_monitor` when `import mpi_monitor` already failed
- Omitting `--hosts` or inventing a host list
- `--match` on `mpirun` / `orted` / `ssh` / other launchers instead of the rank binary
- `--match` against later argv only (e.g. `python3 -c "MARKER=1; …"`) — match
  must appear in comm or argv0 (or shebang argv1)
- Opening `{AGENT_JOB_DIR}/{job_id}/{job_id}.json` (extra directory)
- `pip install` as recovery on this job, or on every compute node — gateway only; remotes use inline payload
- Unbounded `collect` without `--stop-file` (no daemon, no forever loop)
- Fan-out `collect` via `run-slave.sh --command` or `workflow_runner.py`
- Skipping partition preflight / running on excluded nodes
- Using this skill for node RAM/swap (that is `memory-monitor`)
- Overlaying multiple PIDs on one PNG (the CLI writes one file per pid × metric)
- Unbounded Hydra/SSH/firewall diagnosis after wrap failure (retry once, then report)
- `mpi-monitor --help` / `wrap --help` as a liveness check or before the first wrap
  (allowed only after a real wrap failed with a usage error, or if the task asks)

## Reference

Field definitions and examples: [reference.md](reference.md)

中文说明：[SKILL.zh.md](SKILL.zh.md) · [README.zh.md](README.zh.md)

## Master workspace (no this skill)

Master does **not** load this skill. Delegate via agent-to-agent:

```bash
./scripts/submit.sh --partition test --prompt \
  '在 test 分区用 mpi-monitor wrap 包装 MPI 作业：加载 mpi-monitor skill，preflight 后仅在可达节点上 wrap（--hosts 必填，--match 为 rank 二进制 comm/argv0）。采集 CPU/RSS/IO JSONL 与可选 PNG，按契约输出 partition report' \
  --task mpi-monitor
```

Slave probes the CLI first (`probe` / argv array); if missing, fails
immediately. Otherwise one `mpi-monitor wrap` on the gateway after preflight.
