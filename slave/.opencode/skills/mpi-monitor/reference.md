# MPI Monitor — JSON / paths reference

Standalone package (not under ClusterHelm). Gateway install only.

**CLI hard gate:** bash argv array + `"${argv[@]}" probe`, or vendor
`scripts/probe-cli.sh`. Never `"$MPI_MON"` when `MPI_MON` is a multi-word
string (`env PYTHONPATH=… python3 -m mpi_monitor` → `No such file`).
Missing matplotlib is not a hard-gate failure. Do not use `--help` as the gate.

## `meta.json`

```json
{
  "run_id": "20260825T020607Z-59020",
  "hosts": ["cn1", "cn2"],
  "match": "is.S.x",
  "command": ["mpirun", "-np", "2", "-hosts", "cn1,cn2", "/path/to/is.S.x"],
  "interval": 0.1,
  "started_at": "2026-08-25T02:06:07.707141+00:00",
  "ended_at": "2026-08-25T02:06:18.132723+00:00",
  "exit_code": 0,
  "collect_errors": {}
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `run_id` | string | `{YYYYMMDD}T{HHMMSS}Z-{wrap-pid}` |
| `hosts` | string[] | `--hosts` (required; CLI fails if empty) |
| `match` | string | rank **executable** substring (`comm` / argv0; shebang argv1) |
| `command` | string[] | wrapped argv |
| `interval` | float | sample period; default `1.0` |
| `started_at` / `ended_at` | string | UTC ISO-8601 |
| `exit_code` | int | wrapped command status (`wrap` returns this) |
| `collect_errors` | object | per-host start/fetch errors; `{}` if none |

## JSONL sample line

```json
{
  "ts": 1787623567.7478287,
  "host": "cn1",
  "pid": 59020,
  "cpu_pct": 98.4,
  "rss_mb": 15.91,
  "io_read_bps": 0.0,
  "io_write_bps": 4096.0,
  "rank": 0
}
```

| Field | Type | Source |
|-------|------|--------|
| `ts` | float | wall clock (Unix epoch seconds) |
| `host` | string | collector `--host` / short name |
| `pid` | int | matched task PID |
| `cpu_pct` | float | `/proc/<pid>/stat` utime+stime deltas vs wall (`CLK_TCK`) |
| `rss_mb` | float | `/proc/<pid>/status` `VmRSS` |
| `io_read_bps` | float | `/proc/<pid>/io` `read_bytes` delta |
| `io_write_bps` | float | `/proc/<pid>/io` `write_bytes` delta |
| `rank` | int (optional) | `PMIX_RANK`, `OMPI_COMM_WORLD_RANK`, or `PMI_RANK` |

First sample for a PID uses `0.0` for cpu/io rates (no previous snapshot).
`rank` is omitted when none of those env vars are set.

## Discovery (`--match`)

`discover()` matches **comm or argv0** only (interpreter shebang: argv1 when
argv0 is `python*` / `bash` / `sh` / `dash` / `perl` / `ruby`, and argv1 is
not `-c` / `-m`). A match that appears only in later argv is ignored:

- `python3 -m mpi_monitor wrap --match is.S.x -- mpirun … is.S.x` — not sampled
- `mpirun -np 2 is.S.x` — launcher excluded; rank binary sampled if its comm/argv0 matches
- `python3 -c "MARKER=1; …"` — **not** sampled for `--match MARKER` (`-c` skips argv1)

## Discovery excludes

Never sampled even if `--match` also appears in cmdline:

`mpirun`, `mpiexec`, `orted`, `orterun`, `prted`, `prterun`, `sshd`, `ssh`,
`hydra_pmi_proxy`, collector PID.

## Paths

| Artifact | Path |
|----------|------|
| Run root | `{output-dir}/{run_id}/` |
| Metadata | `{run_dir}/meta.json` |
| Series | `{run_dir}/series/{host}_pid{pid}.jsonl` |
| Charts | `{run_dir}/charts/{run_id}_{host}_pid{pid}_{cpu\|rss\|io_read\|io_write}.png` |
| Recommended output-dir | `$AGENT_JOB_DIR/mpi-monitor` or `/home/cn1/agents/var/agent-jobs/mpi-monitor` |
| Job JSON (flat) | `{AGENT_JOB_DIR}/{AGENT_JOB_ID}.json` — print with `job-json` |
| Job incident sidecar | `$CLUSTERHELM_INCIDENT_PATH` (`$AGENT_JOB_DIR/<job_id>.incident.json`); written when wrap exit ≠ 0 |
| Gateway CLI tree | `/home/cn1/agents/vendor/mpi-monitor` (via `deploy-mpi-monitor.sh`) |
| Gateway venv CLI | `/home/cn1/agents/vendor/mpi-monitor/.venv/bin/mpi-monitor` |
| Probe script | `/home/cn1/agents/vendor/mpi-monitor/scripts/probe-cli.sh` |
| Remote collector scratch | `/tmp/mpi-monitor/{run_id}/{host}/` (fetched after wrap) |

**Wrong job JSON path:** `{AGENT_JOB_DIR}/{job_id}/{job_id}.json` (extra
directory). Use `"${argv[@]}" job-json` or `job-json --require`.

One PNG per process × metric. Missing matplotlib: skip PNG, keep JSONL, do not
fail wrap for plotting.

## CLI

| Subcommand | Role |
|------------|------|
| `probe` | Hard gate: print `ok` and exit 0 if this package can run |
| `job-json` | Print `{AGENT_JOB_DIR}/{AGENT_JOB_ID}.json` (not nested). `--require` exits 2 if missing |
| `wrap` | Happy path: start collectors → run command → stop → fetch → optional plot |
| `collect` | Node-local loop; requires `--stop-file` |
| `plot` | Rebuild PNG from an existing `--run-dir` |
| `remote-cmd` | Print inline `base64 \| python3` collector (used internally by wrap) |

`wrap` flags: `--hosts` (required), `--match`, `--output-dir`, `--interval`,
`--ready-timeout` (default 30s; also the SSH start timeout), `--join-timeout`
(default 5s), `--ssh-user`, `--ssh-identity`, then `--` and the command.

Remote start command (implementation):

```text
mkdir -p … && (setsid bash -c '<payload>' >/dev/null 2>collect.err </dev/null &) && echo OK
```

SSH uses `-T -n`. Do **not** use `nohup` for this cluster — it holds the
session. After detach, SSH should return immediately; if SSH itself is slow
(WSL proxy), raise `--ready-timeout`.

## Stable wrap I/O contract

- The wrapped command inherits `wrap` stdout and stderr. Redirecting
  `wrap 1>program.stdout 2>monitor.stderr` captures the complete program
  stdout separately from monitor/launcher diagnostics.
- Local collectors suppress their own stdout/stderr; remote collector errors
  are fetched as collector diagnostics. They do not replace wrapped-command
  output.
- Custom CSV schemas, combined plots, aggregate summaries, and report-specific
  base64 are job-local post-processing concerns. Generate those scripts once
  per job from the JSONL contract above.
- Store large base64 fields directly in the structured job JSON. Human-readable
  markdown should contain the artifact path, byte size, and encoded length.

These are public behavioral guarantees. A Slave agent following the happy path
must not inspect `wrap.py`, `cli.py`, `collect.py`, or `discover.py` to verify
them again.

## Exception result contract

Use these stable reason codes: `hard_gate_failed`, `insufficient_hosts`,
`wrapped_command_failed`, `collection_incomplete`, `postprocess_failed`, and
`report_finalize_failed`.

The structured failure object contains:

```json
{
  "stage": "postprocess",
  "reason_code": "postprocess_failed",
  "retry_allowed": true,
  "attempt": 1,
  "message": "combined PNG generation failed",
  "preserved_artifacts": ["program.stdout", "meta.json", "series/"]
}
```

Stage completion is monotonic: never discard valid raw output, metadata, or
series, and never rerun a successful wrapped command to repair a later stage.
Post-processing and finalization may each be retried once from preserved
artifacts when the job deadline permits.

## Notes

- Not ClusterHelm `memmon.py` / `memory-monitor` (host RAM) and not nodestat
  (host snapshots, no PID).
- Compute nodes need no package install; wrap sends the zip+boot payload over SSH.
- Probe the CLI on the gateway first (`probe` / `probe-cli.sh`); abort if
  missing. Only then wrap after partition preflight.
- Invoke via argv list expansion (`"${argv[@]}"`). `resolve_cli_argv()` in the
  package returns a list, never a single multi-word string.
