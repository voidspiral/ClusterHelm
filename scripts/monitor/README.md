# Memory monitor (simulation phase)

## Deploy

| Script | Scope |
|--------|--------|
| [`deploy-slave.sh`](../jobs/deploy-slave.sh) | Slave **agent**: rules, skills, `run-slave.sh`, partition/exclusion config |
| [`deploy-monitor.sh`](deploy-monitor.sh) | **This directory** only: `memmon.py`, `mem-api.sh`, `master.conf` (poll settings for mem-api) on gateway |

```bash
./scripts/jobs/deploy-slave.sh cn1
./scripts/monitor/deploy-monitor.sh cn1   # optional
```

## Deployment today

| Artifact | cn1 (gateway) | cn2–cn10 |
|----------|---------------|----------|
| `memmon.py`, `mem-api.sh` | `deploy-monitor.sh` | **not deployed** |
| Partition memory collect | via `mem-api.sh` / nested job `--command` | inline via `--remote-cmd` |

The test partition worker SSHs the job `--command` to every reachable node — a path like `python3 /home/smt/agents/.../memmon.py` **fails on cn2–cn10** unless those nodes have the file.

## Simulation (current)

Partition jobs use a **self-contained remote command** (no file on target):

```bash
python3 scripts/monitor/memmon.py --remote-cmd
# → echo <base64> | base64 -d | python3
```

`mem-api.sh partition` uses this as nested `--command`. Requirements on each node: `python3`, `base64`, `/proc/meminfo`.

## Future

A **uniform node interface** (HTTP agent, package install to all compute nodes, etc.) will replace inline `--remote-cmd`. Then `--command` can point at the installed collector on every node.

## Usage

```bash
# Gateway local (file on cn1, after deploy-monitor)
./scripts/monitor/mem-api.sh local

# Partition (Slave gateway — inline on all reachable nodes)
./scripts/monitor/mem-api.sh partition test

# Master delegate (agent-to-agent — default)
./scripts/jobs/submit.sh --partition test --prompt \
  '检查 test 分区各节点内存与 swap，加载 memory-monitor skill，preflight 后采集，汇总 mem_used_pct 并输出 partition report' \
  --task memory-monitor
./scripts/jobs/poll-wait.sh --job-id <job_id>

# Script-mode fallback (only when user explicitly requests --command)
CMD=$(python3 scripts/monitor/memmon.py --remote-cmd)
./scripts/jobs/submit.sh --partition test --command "$CMD" --task memory-monitor
```
