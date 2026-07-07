# Cluster Agent Control Plane

Master/slave Cursor agents for async partition execution.

**中文：** [`docs/zh/README.md`](docs/zh/README.md) · [架构图](docs/architecture.md) · [配置说明](docs/zh/config.md) · [Master](docs/zh/master-agent.md) · [Slave](docs/zh/slave-agent.md)

## Config vs rules

| Layer | Files | Role |
|-------|-------|------|
| **Facts** | `partitions.conf`, `slaves.conf`, `master.conf` | Partitions, slave registry, timeouts |
| **Behavior** | `.cursor/rules/*.mdc` | How to submit/poll/preflight; points at config |

```bash
./scripts/jobs/list-slaves.py          # show managed slaves
./scripts/jobs/list-slaves.py --json
```

## Layout

```
.cursor/rules/master-agent.mdc          # Master Cursor rule (source)
.opencode/agents/master-agent.md        # Master OpenCode agent
opencode.json                           # default_agent=master-agent

deploy/slave-agent/
  .cursor/rules/slave-agent.mdc         # Slave Cursor rule (deploy source)
  .opencode/agents/slave-agent.md       # Slave OpenCode agent (deploy source)
  opencode.json                         # default_agent=slave-agent

scripts/jobs/
  partitions.conf    # test → cn[1-10]
  slaves.conf        # cn1 → test
  master.conf        # defaults, poll backoff
  slave.conf         # node exclusion + agent_runtime (cursor/opencode)
  deploy-master.sh   # deploy Master agent (local or remote host)
  deploy-slave.sh    # deploy Slave agent to gateway
  deploy-all.sh      # deploy Master + Slave in one step
  list-slaves.py     # registry + routing
  submit.sh / poll.sh / run-slave.sh
var/agent-jobs/
```

## Deploy (sync Master + Slave)

| Script | Target | What it installs |
|--------|--------|------------------|
| `deploy-master.sh [HOST\|local]` | Master (default: this workspace) | `master-agent.mdc` → `~/.cursor/rules/`, `.opencode/agents/master-agent.md`, `opencode.json`, `submit.sh` / `poll.sh` / `master.conf` |
| `deploy-slave.sh <gateway>` | Slave gateway (e.g. `cn1`) | `slave-agent.mdc` → `~/.cursor/rules/`, `.opencode/` (agents + skills), `opencode.json`, `run-slave.sh` / `slave.conf`, `/var/agent-jobs/` |
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
./scripts/jobs/submit.sh --partition test --command 'hostname'     # script mode
./scripts/jobs/submit.sh --partition test --prompt '<task>'        # agent mode (agent-to-agent)
./scripts/jobs/poll.sh --job-id job-...
```

Gateway auto-selected from `slaves.conf` unless `--gateway` is set.

## Delegation modes

| Mode | Flag | Gateway executor |
|------|------|------------------|
| Script | `--command '<cmd>'` | Deterministic worker (`run-slave.sh _worker`): preflight → exec → `partition_report` |
| Agent | `--prompt '<task>'` | **Slave agent LLM**, launched via Cursor CLI (`agent -p`) or OpenCode CLI (`opencode run --agent slave-agent`); runtime chosen by gateway `slave.conf: agent_runtime` (`auto|cursor|opencode`, overridable per job with `--runtime`) |

Agent-mode jobs share the same job JSON and polling; the agent's final output must follow the report contract (`AGENT_STATUS` + `===PARTITION_REPORT_BEGIN/END===`), which the gateway parses into `partition_report`.
