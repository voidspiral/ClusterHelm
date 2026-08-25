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

**Hard gate (before preflight or wrap):** probe the CLI on this gateway. If it
is not installed, mark the job **failed** and **stop**. Do not preflight, wrap,
`pip install`, SSH compute nodes, or invent series.

## When to use

- User wants process-level CPU / RSS / IO for MPI ranks or a matched binary
- User asks to **wrap** `mpirun` / `mpiexec` with a sidecar collector
- User asks for per-PID JSONL timeseries or per-process PNG charts
- Short HPC jobs (NPB class S, sub-second) that need `--interval` &lt; 1s
- **Not** for node RAM/swap/OOM (use `memory-monitor`) or host heartbeat (use `nodestatus`)

## Commands

Gateway `$remote_project` is `/home/cn1/agents` (`master.conf`). Put run output
under the job dir when `AGENT_JOB_DIR` is set.

### CLI hard gate (mandatory, first)

Installed means any one of: PATH `mpi-monitor`, the gateway venv binary, or
`import mpi_monitor` via vendor `PYTHONPATH` / system site-packages.
Missing matplotlib is **not** a failure (PNG is optional).

```bash
VENDOR="${REMOTE_PROJECT:-/home/cn1/agents}/vendor/mpi-monitor"
VENV_BIN="$VENDOR/.venv/bin/mpi-monitor"
if command -v mpi-monitor >/dev/null 2>&1; then
  MPI_MON=mpi-monitor
elif [[ -x "$VENV_BIN" ]]; then
  MPI_MON="$VENV_BIN"
elif PYTHONPATH="$VENDOR/src${PYTHONPATH:+:$PYTHONPATH}" python3 -c "import mpi_monitor" >/dev/null 2>&1; then
  MPI_MON="env PYTHONPATH=$VENDOR/src python3 -m mpi_monitor"
elif python3 -c "import mpi_monitor" >/dev/null 2>&1; then
  MPI_MON="python3 -m mpi_monitor"
else
  echo "mpi-monitor CLI is not installed on this gateway" >&2
  exit 2
fi
OUT="${AGENT_JOB_DIR:-/home/cn1/agents/var/agent-jobs}/mpi-monitor"
mkdir -p "$OUT"
```

On `exit 2`: write the failed `partition_report` below and terminate. Do not
continue the job flow.

### Happy path — wrap (required `--hosts`)

`--hosts` is **required**. `--match` is a substring of `/proc/<pid>/cmdline`
for the **rank binary**, not `mpirun`. Default `--interval` is `1.0`; short
jobs should pass `0.1` or `0.05`. Exit status equals the wrapped command.

```bash
# HOSTS = reachable ∩ owned partition ∩ the MPI host list from the task
$MPI_MON wrap \
  --hosts cn1,cn2,cn3 \
  --match is.S.x \
  --output-dir "$OUT" \
  --interval 0.1 \
  -- \
  mpirun -np 2 -ppn 1 -hosts cn1,cn2 /path/to/is.S.x
```

Local short hostname and `localhost` collect in-process; other names use SSH
(`--ssh-user`, `--ssh-identity` if needed). Remote collectors write under
`/tmp/mpi-monitor/{run_id}/{host}` then `wrap` fetches JSONL back.

Single-node / local ranks: `--hosts "$(hostname -s)"`.

### Debug only — collect / plot / remote-cmd

Do **not** use these as the partition happy path.

```bash
$MPI_MON collect --match BIN --output-dir DIR --stop-file FILE --host HOST
$MPI_MON plot --run-dir DIR
$MPI_MON remote-cmd -- collect --match BIN --output-dir DIR --stop-file FILE --host HOST
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
| `match` | cmdline substring |
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
`prterun`, `sshd`, `hydra_pmi_proxy`, and the collector PID.

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

1. **CLI hard gate** on this gateway (block above). Missing install → failed
   report, **stop**. No preflight, wrap, or `pip install`.
2. Preflight the owned partition (nodestatus → ping/SSH fallback). Do not wrap
   on excluded or unreachable nodes.
3. Build `--hosts` from reachable hosts ∩ the MPI host list in the task.
   Never invent hostnames.
4. On **this gateway**, run **one** `mpi-monitor wrap … -- CMD`.
5. Read `{output-dir}/{run_id}/meta.json`; list `series/` and `charts/`.
6. Write one `partition_report`. Wrap's exit code is the MPI/command status.

Low-level debug (not the happy path): `collect` with an explicit `--stop-file`,
or `plot --run-dir` after JSONL exists.

## Forbidden

- Continuing after a failed CLI hard gate (no wrap, no pip, no SSH, no fake series)
- Using `python3 -m mpi_monitor` when `import mpi_monitor` already failed
- Omitting `--hosts` or inventing a host list
- `--match` on `mpirun` / `orted` / other launchers instead of the rank binary
- `pip install` as recovery on this job, or on every compute node — gateway only; remotes use inline payload
- Unbounded `collect` without `--stop-file` (no daemon, no forever loop)
- Fan-out `collect` via `run-slave.sh --command` or `workflow_runner.py`
- Skipping partition preflight / running on excluded nodes
- Using this skill for node RAM/swap (that is `memory-monitor`)
- Overlaying multiple PIDs on one PNG (the CLI writes one file per pid × metric)

## Reference

Field definitions and examples: [reference.md](reference.md)

中文说明：[SKILL.zh.md](SKILL.zh.md) · [README.zh.md](README.zh.md)

## Master workspace (no this skill)

Master does **not** load this skill. Delegate via agent-to-agent:

```bash
./scripts/submit.sh --partition test --prompt \
  '在 test 分区用 mpi-monitor wrap 包装 MPI 作业：加载 mpi-monitor skill，preflight 后仅在可达节点上 wrap（--hosts 必填，--match 为 rank 二进制）。采集 CPU/RSS/IO JSONL 与可选 PNG，按契约输出 partition report' \
  --task mpi-monitor
```

Slave probes the CLI first; if missing, fails immediately. Otherwise one
`mpi-monitor wrap` on the gateway after preflight.
