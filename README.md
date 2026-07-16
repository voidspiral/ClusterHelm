# Cluster Agent Control Plane

Master/Slave agents for async partition execution. Supports **OpenCode** runtime on both sides.

**中文：** [`docs/zh/README.md`](docs/zh/README.md) · [架构图](docs/architecture.md) · [配置说明](docs/zh/config.md) · [Master](docs/zh/master-agent.md) · [Slave](docs/zh/slave-agent.md)

## Config vs agent behavior

| Layer | Files | Role |
|-------|-------|------|
| **Facts** | `partitions.conf`, `slaves.conf`, `master.conf`, `slave.conf` | Partitions, slave registry, timeouts, runtime defaults |
| **Behavior** | `.opencode/agents/*.md`, `.opencode/skills/` | How Master/Slave agents submit, poll, preflight, and delegate; points at config |

```bash
./scripts/jobs/list-slaves.py          # show managed slaves
./scripts/jobs/list-slaves.py --json
```

## Layout

```
.opencode/agents/master-agent.md        # Master agent (OpenCode)
.opencode/skills/                       # Master skills (e.g. add-tools2)
opencode.json                           # default_agent=master-agent

deploy/slave-agent/
  .opencode/agents/slave-agent.md       # Slave agent (OpenCode, deploy source)
  .opencode/skills/                     # Slave skills (e.g. memory-monitor)
  opencode.json                         # default_agent=slave-agent

scripts/jobs/
  partitions.conf    # test → cn[1-10]
  slaves.conf        # cn1 → test
  master.conf        # defaults, poll backoff
  slave.conf         # node exclusion + agent_opencode_bin
  deploy-master.sh   # deploy Master agent (local or remote host)
  deploy-slave.sh    # deploy Slave agent to gateway
  deploy-all.sh      # deploy Master + Slave in one step
  list-slaves.py     # registry + routing
  submit.sh / poll-wait.sh / run-slave.sh
var/agent-jobs/
```

## Agent runtimes

| Runtime | Master | Slave (gateway) |
|---------|--------|-----------------|
| **OpenCode** | `.opencode/agents/master-agent.md` | `.opencode/agents/slave-agent.md` + skills |

Gateway `slave.conf: agent_opencode_bin` selects the OpenCode CLI.

## Deploy (sync Master + Slave)

| Script | Target | What it installs |
|--------|--------|------------------|
| `deploy-master.sh [HOST\|local]` | Master (default: this workspace) | OpenCode agent + `opencode.json`, `submit.sh` / `poll-wait.sh` / `master.conf` |
| `deploy-slave.sh <gateway>` | Slave gateway (e.g. `cn1`) | OpenCode agents/skills + `opencode.json`, `run-slave.sh` / `slave.conf`, `/home/smt/agents/var/agent-jobs/` |
| `deploy-all.sh <gateway> [master-host]` | Both | Runs `deploy-master.sh` then `deploy-slave.sh` |

```bash
# Deploy both sides (Master local + Slave cn1)
./scripts/jobs/deploy-all.sh cn1

# Or separately
./scripts/jobs/deploy-master.sh              # local Master
./scripts/jobs/deploy-master.sh <master-host>  # remote Master over SSH
./scripts/jobs/deploy-slave.sh cn1           # Slave gateway

# Optional: memory monitor CLI on gateway
./scripts/monitor/deploy-monitor.sh cn1
```

After deploy, each side uses its own OpenCode default agent:

| Node | `opencode.json` | OpenCode agent |
|------|-----------------|----------------|
| Master | `default_agent: master-agent` | `.opencode/agents/master-agent.md` |
| Slave (cn1) | `default_agent: slave-agent` | `deploy/slave-agent/.opencode/agents/slave-agent.md` |

## Quick start

```bash
./scripts/jobs/deploy-all.sh cn1            # sync Master + Slave first
./scripts/jobs/submit.sh --partition test --prompt '<task>'        # agent mode (default, agent-to-agent)
./scripts/jobs/submit.sh --partition test --command 'hostname'     # script mode (exception only)
./scripts/jobs/poll-wait.sh --job-id job-...
```

Gateway auto-selected from `slaves.conf` unless `--gateway` is set.

## Delegation modes

| Mode | Flag | Gateway executor |
|------|------|------------------|
| Script | `--command '<cmd>'` | Deterministic worker (`run-slave.sh _worker`): preflight → exec → `partition_report` |
| Agent | `--prompt '<task>'` | **Slave agent LLM** on gateway via OpenCode; runtime from `slave.conf: agent_opencode_bin` |

Agent-mode jobs share the same job JSON and polling; the agent's final output must follow the report contract (`AGENT_STATUS` + `===PARTITION_REPORT_BEGIN/END===`), which the gateway parses into `partition_report`.
