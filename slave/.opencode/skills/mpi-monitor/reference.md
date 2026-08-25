# MPI Monitor — JSON / paths reference

Standalone package (not under ClusterHelm). Gateway install only.

**CLI hard gate:** PATH `mpi-monitor` **or** `python3 -c "import mpi_monitor"`.
If both fail, the skill **aborts** (job `failed`) before preflight/wrap.
Missing matplotlib is not a hard-gate failure.

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
| `match` | string | `/proc/<pid>/cmdline` substring (rank binary) |
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

## Discovery excludes

Never sampled even if `--match` also appears in cmdline:

`mpirun`, `mpiexec`, `orted`, `orterun`, `prted`, `prterun`, `sshd`,
`hydra_pmi_proxy`, collector PID.

## Paths

| Artifact | Path |
|----------|------|
| Run root | `{output-dir}/{run_id}/` |
| Metadata | `{run_dir}/meta.json` |
| Series | `{run_dir}/series/{host}_pid{pid}.jsonl` |
| Charts | `{run_dir}/charts/{run_id}_{host}_pid{pid}_{cpu\|rss\|io_read\|io_write}.png` |
| Recommended output-dir | `$AGENT_JOB_DIR/mpi-monitor` or `/home/cn1/agents/var/agent-jobs/mpi-monitor` |
| Gateway CLI tree | `/home/cn1/agents/vendor/mpi-monitor` (via `deploy-mpi-monitor.sh`) |
| Gateway venv CLI | `/home/cn1/agents/vendor/mpi-monitor/.venv/bin/mpi-monitor` |
| Remote collector scratch | `/tmp/mpi-monitor/{run_id}/{host}/` (fetched after wrap) |

One PNG per process × metric. Missing matplotlib: skip PNG, keep JSONL, do not
fail wrap for plotting.

## CLI

| Subcommand | Role |
|------------|------|
| `wrap` | Happy path: start collectors → run command → stop → fetch → optional plot |
| `collect` | Node-local loop; requires `--stop-file` |
| `plot` | Rebuild PNG from an existing `--run-dir` |
| `remote-cmd` | Print inline `base64 \| python3` collector (used internally by wrap) |

`wrap` flags: `--hosts` (required), `--match`, `--output-dir`, `--interval`,
`--ready-timeout` (default 30s), `--join-timeout` (default 5s), `--ssh-user`,
`--ssh-identity`, then `--` and the command.

## Notes

- Not ClusterHelm `memmon.py` / `memory-monitor` (host RAM) and not nodestat
  (host snapshots, no PID).
- Compute nodes need no package install; wrap sends the zip+boot payload over SSH.
- Probe the CLI on the gateway first; abort if missing. Only then wrap after
  partition preflight.
