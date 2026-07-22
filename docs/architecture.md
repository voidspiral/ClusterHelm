# Architecture

**中文：** [`docs/zh/architecture.md`](zh/architecture.md)

Master/Slave agent control plane for async partition execution. Master delegates to Slave gateways; Slave owns preflight, execution, and the centralized `partition_report`.

## Overview

| Layer | Host | Role |
|-------|------|------|
| **Master** | Local workspace (or remote Master host) | Orchestrator: `submit.sh` → `poll-wait.sh` → present `partition_report` |
| **Slave gateway** | e.g. `cn1` | Partition owner for `test` → `cn[1-10]` |
| **Compute nodes** | `cn1`–`cn10` | Execution targets (preflight + exec from gateway only) |

**Hard rule:** Master SSHs **only to the gateway**, never directly to compute nodes for partition work.

---

## Full architecture

```mermaid
flowchart TB
  subgraph User["User / Operator"]
    U[Natural-language task or exact command]
  end

  subgraph Master["Master node (workspace)"]
    MA["Master Agent LLM<br/>OpenCode: master-agent"]
    MS[submit.sh]
    MP[poll-wait.sh]
    MC[master.conf / slaves.conf / partitions.conf]
    MJ[var/agent-jobs/*.last.json]
    MA --> MS
    MA --> MP
    MS --> MC
    MP --> MJ
  end

  subgraph Gateway["Slave gateway cn1 (partition owner)"]
    direction TB
    RS[run-slave.sh]
    SC[slave.conf<br/>agent_opencode_bin]
    SJ[/home/smt/agents/var/agent-jobs/job-*.json/]
    SA["Slave Agent LLM<br/>OpenCode: slave-agent"]
    WK["_worker<br/>deterministic script worker"]
    AW["_agent_worker<br/>launches Slave agent CLI"]
    RS --> SJ
    RS -->|script mode --command| WK
    RS -->|agent mode --prompt| AW
    AW --> SA
    SC --> AW
    SA --> RS
  end

  subgraph Nodes["Compute nodes (test partition)"]
    N1[cn1]
    N2[cn2]
    N3[cn3]
    N10[cn10]
  end

  U --> MA
  MS -->|SSH to gateway only| RS
  MP -->|SSH poll| RS
  WK -->|preflight ping/SSH + exec| N1
  WK --> N2
  WK --> N3
  WK --> N10
  SA -->|may nest script-mode jobs| RS
  RS -->|partition_report.markdown| MP
  MP --> MA
```

---

## Simplified: data flow

```mermaid
flowchart LR
  U[User] --> MA[Master Agent]
  MA -->|submit| G[cn1 gateway]
  G -->|preflight + exec| N[cn1..cn10]
  N -->|per-node results| G
  G -->|partition_report| MA
  MA --> U

  style MA fill:#e8f4fc
  style G fill:#fff4e6
  style N fill:#f0f0f0
```

**Job JSON** is the contract between Master and gateway:

```
submit.sh  ──SSH──►  run-slave.sh submit  ──►  /home/smt/agents/var/agent-jobs/<job_id>.json
poll-wait.sh    ──SSH──►  run-slave.sh poll    ◄──  same JSON (+ partition_report at end)
```

Master caches the latest poll in `var/agent-jobs/<job_id>.last.json`.

---

## Simplified: deployment

```mermaid
flowchart LR
  subgraph Repo["Repository"]
    DA[deploy-all.sh]
    DM[deploy-master.sh]
    DS[deploy-slave.sh]
  end

  subgraph MasterHost["Master host"]
    MOC[master-agent.md]
    MJ[submit.sh / poll-wait.sh]
  end

  subgraph Cn1["Slave gateway cn1"]
    SOC[slave-agent.md]
    RJ[run-slave.sh / slave.conf]
    JD[/home/smt/agents/var/agent-jobs/]
  end

  DA --> DM
  DA --> DS
  DM --> MOC
  DM --> MJ
  DS --> SOC
  DS --> RJ
  DS --> JD
```

```bash
./scripts/deploy/deploy-all.sh cn1          # Master (local) + Slave (cn1)
./scripts/deploy/deploy-master.sh           # Master only
./scripts/deploy/deploy-slave.sh cn1        # Slave only
```

| Side | OpenCode default |
|------|------------------|
| Master | `master-agent` |
| Slave (cn1) | `slave-agent` |

---

## Delegation modes

```mermaid
sequenceDiagram
  participant User as User
  participant MA as Master Agent
  participant SS as submit.sh
  participant PS as poll-wait.sh
  participant RS as run-slave.sh (cn1)
  participant Exec as _worker / Slave Agent
  participant Node as cn1..cn10

  User->>MA: partition task
  alt Script mode (--command)
    MA->>SS: submit --command 'hostname -s'
    SS->>RS: SSH submit
    RS->>Exec: _worker
    Exec->>Node: preflight + exec
    Exec->>RS: write partition_report
  else Agent mode (--prompt, agent-to-agent)
    MA->>SS: submit --prompt 'check hostnames'
    SS->>RS: SSH submit
    RS->>Exec: _agent_worker
    Exec->>Exec: opencode run --agent slave-agent
    Exec->>RS: may nest run-slave.sh --command
    RS->>Node: preflight + exec
    Exec->>RS: AGENT_STATUS + PARTITION_REPORT contract
    RS->>RS: parse into partition_report
  end
  loop poll until done|partial|failed
    MA->>PS: poll --job-id
    PS->>RS: SSH poll
    RS-->>PS: job JSON
  end
  MA->>User: present partition_report.markdown
```

| Mode | Flag | Gateway executor | When to use |
|------|------|------------------|-------------|
| **Script** | `--command '<cmd>'` | `_worker` (deterministic) | Exact command known; fast path |
| **Agent** | `--prompt '<task>'` | Slave agent LLM via OpenCode CLI | Judgment, diagnosis, multi-step |

Both modes produce the same `partition_report` in job JSON; Master reporting flow is identical.

---

## Runtime selection (Slave, agent mode only)

Agent mode always uses OpenCode: `opencode run --agent slave-agent`.

Config in `slave/config/slave.conf`:

```ini
agent_opencode_bin opencode
agent_opencode_agent slave-agent
```

---

## Responsibility boundary

| Layer | Does | Does not |
|-------|------|----------|
| **Master Agent** | Submit to gateway, poll job, present `partition_report.markdown` | SSH/exec on cn2–cn10; assemble node status from raw `nodes.*` |
| **Slave gateway** | Preflight, node exclusion, exec, centralized report | Operate outside owned partition |
| **Script mode** | Deterministic per-node run | LLM reasoning |
| **Agent mode** | Slave LLM plans and reports | As fast as script mode |

---

## File map

```
Master (workspace)                    Slave gateway (cn1)
────────────────────────────────────────────────────────────────
master/.opencode/agents/master-agent.md (Master only)
opencode.json (master-agent)
master/config/master.conf
master/scripts/{submit,poll,poll-wait}.sh
shared/{partitions,slaves}.conf

slave/              →   deployed flat to /home/smt/agents/ via deploy-slave.sh
  .opencode/        →   .opencode/
  opencode.json     →   opencode.json
  config/slave.conf →   config/slave.conf
  scripts/run-slave.sh → scripts/run-slave.sh
  scripts/preflight/   → scripts/preflight/
  shared/              → shared/

master/scripts/submit.sh      SSH →    (Master only)
master/scripts/poll-wait.sh  SSH →    scripts/run-slave.sh wait (blocks until terminal)
                                     scripts/run-slave.sh submit / _worker / _agent_worker
var/agent-jobs/*.last.json  ←──      /home/smt/agents/var/agent-jobs/*.json
```

---

## Config routing (test partition)

| File | Example | Purpose |
|------|---------|---------|
| `shared/partitions.conf` | `test cn[1-10]` | Logical partition → nodeset |
| `shared/slaves.conf` | `cn1 test cn[1-10]` | Gateway registry |
| `master/config/master.conf` | `default_gateway cn1` | Master defaults, poll backoff |
| `slave/config/slave.conf` | `agent_opencode_bin opencode` | Exclusion policy + agent CLI |

```bash
./master/scripts/list-slaves.py --partition test   # → cn1
```

---

## One-line summary

**Master talks only to the gateway; the gateway (Slave agent or deterministic worker) owns the whole partition and returns one `partition_report` — same job JSON and poll protocol for both script and agent modes.**
