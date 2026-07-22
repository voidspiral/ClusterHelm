# Cluster Agent Control Plane

Master/Slave agents for async partition execution. Supports **OpenCode** runtime on both sides.

**中文：** [`docs/zh/README.md`](docs/zh/README.md) · [架构图](docs/architecture.md) · [配置说明](docs/zh/config.md) · [Master](docs/zh/master-agent.md) · [Slave](docs/zh/slave-agent.md)

## Config vs agent behavior

| Layer | Files | Role |
|-------|-------|------|
| **Facts** | `master/config/{partitions,slaves,master}.conf`, `slave/config/slave.conf` | Partitions, slave registry, timeouts, runtime defaults |
| **Behavior** | `master/.opencode/agents/*.md`, `slave/.opencode/agents/*.md`, skills | How Master/Slave agents submit, poll, preflight, and delegate; points at config |

```bash
./master/scripts/list-slaves.py          # show managed slaves
./master/scripts/list-slaves.py --json
```

## Layout

```
master/
  .opencode/agents/master-agent.md   # Master agent (OpenCode)
  .opencode/skills/                  # Master skills (e.g. add-tools2)
  opencode.json                      # default_agent=master-agent
  config/
    master.conf                      # defaults, poll backoff
    partitions.conf                  # SoT: test → cn[1-10]
    slaves.conf                      # SoT: cn1 → test
  scripts/                           # submit.sh, poll.sh, poll-wait.sh, list-slaves.py

slave/
  .opencode/agents/slave-agent.md    # Slave agent (OpenCode, deploy source)
  .opencode/skills/                  # Slave skills (e.g. memory-monitor)
  opencode.json                      # default_agent=slave-agent
  config/slave.conf                  # node exclusion + agent_opencode_bin
  scripts/run-slave.sh
  scripts/resolve-partition.py       # reads config/partitions.conf (deployed from Master)
  scripts/preflight/                 # job_preflight.py, node_exclude.py

scripts/deploy/                      # deploy-master/slave/all, test-agent-chain
scripts/monitor/                     # memmon + deploy-monitor (optional)
scripts/mpi/

var/agent-jobs/
```

## Agent runtimes

| Runtime | Master | Slave (gateway) |
|---------|--------|-----------------|
| **OpenCode** | `master/.opencode/agents/master-agent.md` | `slave/.opencode/agents/slave-agent.md` + skills |

Run Master OpenCode from `master/` (that directory is the OpenCode project root). Gateway `slave/config/slave.conf: agent_opencode_bin` selects the OpenCode CLI.

## Deploy (sync Master + Slave)

| Script | Target | What it installs |
|--------|--------|------------------|
| `deploy-master.sh [HOST\|local]` | Master (default: this workspace) | OpenCode agent + `opencode.json`, `submit.sh` / `poll-wait.sh` / `master.conf` |
| `deploy-slave.sh <gateway>` | Slave gateway (e.g. `cn1`) | OpenCode agents/skills + `opencode.json`, `run-slave.sh` / `slave.conf`, `/home/smt/agents/var/agent-jobs/` |
| `deploy-all.sh <gateway> [master-host]` | Both | Runs `deploy-master.sh` then `deploy-slave.sh` |

```bash
# Deploy both sides (Master local + Slave cn1)
./scripts/deploy/deploy-all.sh cn1

# Or separately
./scripts/deploy/deploy-master.sh              # local Master
./scripts/deploy/deploy-master.sh <master-host>  # remote Master over SSH
./scripts/deploy/deploy-slave.sh cn1           # Slave gateway

# Optional: memory monitor CLI on gateway
./scripts/monitor/deploy-monitor.sh cn1
```

After deploy, each side uses its own OpenCode default agent:

| Node | `opencode.json` | OpenCode agent |
|------|-----------------|----------------|
| Master | `default_agent: master-agent` | `master/.opencode/agents/master-agent.md` |
| Slave (cn1) | `default_agent: slave-agent` | `slave/.opencode/agents/slave-agent.md` |

## Quick start

```bash
./scripts/deploy/deploy-all.sh cn1            # sync Master + Slave first
./master/scripts/submit.sh --partition test --prompt '<task>'        # agent mode (default, agent-to-agent)
./master/scripts/submit.sh --partition test --command 'hostname'     # script mode (exception only)
./master/scripts/poll-wait.sh --job-id job-...
```

Gateway auto-selected from `slaves.conf` unless `--gateway` is set.

## Delegation modes

| Mode | Flag | Gateway executor |
|------|------|------------------|
| Script | `--command '<cmd>'` | Deterministic worker (`run-slave.sh _worker`): preflight → exec → `partition_report` |
| Agent | `--prompt '<task>'` | **Slave agent LLM** on gateway via OpenCode; runtime from `slave.conf: agent_opencode_bin` |

Agent-mode jobs share the same job JSON and polling; the agent's final output must follow the report contract (`AGENT_STATUS` + `===PARTITION_REPORT_BEGIN/END===`), which the gateway parses into `partition_report`.
