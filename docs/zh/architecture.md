# 架构说明

**English:** [`docs/architecture.md`](../architecture.md)

Master/Slave 双 Agent 控制面：Master 委托 Slave 网关异步执行分区任务；Slave 负责 preflight、执行与集中式 `partition_report`。

## 总览

| 层级 | 主机 | 职责 |
|------|------|------|
| **Master** | 本机工作区（或远程 Master 主机） | 编排：`submit.sh` → `poll-wait.sh` → 呈现 `partition_report` |
| **Slave 网关** | 如 `cn1` | 分区 owner，管理 `test` → `cn[1-10]` |
| **计算节点** | `cn1`–`cn10` | 执行目标（仅由网关 preflight + exec） |

**硬性约束：** Master 对分区任务 **只 SSH 到网关**，不直接操作计算节点。

---

## 完整架构

```mermaid
flowchart TB
  subgraph User["用户 / 运维"]
    U[自然语言任务或明确命令]
  end

  subgraph Master["Master 节点（工作区）"]
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

  subgraph Gateway["Slave 网关 cn1（分区 owner）"]
    direction TB
    RS[run-slave.sh]
    SC[slave.conf<br/>agent_opencode_bin]
    SJ[/home/smt/agents/var/agent-jobs/job-*.json/]
    SA["Slave Agent LLM<br/>OpenCode: slave-agent"]
    WK["_worker<br/>确定性脚本 worker"]
    AW["_agent_worker<br/>启动 Slave agent CLI"]
    RS --> SJ
    RS -->|script 模式 --command| WK
    RS -->|agent 模式 --prompt| AW
    AW --> SA
    SC --> AW
    SA --> RS
  end

  subgraph Nodes["计算节点（test 分区）"]
    N1[cn1]
    N2[cn2]
    N3[cn3]
    N10[cn10]
  end

  U --> MA
  MS -->|仅 SSH 到网关| RS
  MP -->|SSH poll| RS
  WK -->|preflight ping/SSH + exec| N1
  WK --> N2
  WK --> N3
  WK --> N10
  SA -->|可嵌套 script 模式任务| RS
  RS -->|partition_report.markdown| MP
  MP --> MA
```

---

## 简化：数据流

```mermaid
flowchart LR
  U[用户] --> MA[Master Agent]
  MA -->|submit| G[cn1 网关]
  G -->|preflight + exec| N[cn1..cn10]
  N -->|各节点结果| G
  G -->|partition_report| MA
  MA --> U

  style MA fill:#e8f4fc
  style G fill:#fff4e6
  style N fill:#f0f0f0
```

**Job JSON** 是 Master 与网关之间的契约：

```
submit.sh     ──SSH──►  run-slave.sh submit  ──►  /home/smt/agents/var/agent-jobs/<job_id>.json
poll-wait.sh  ──SSH──►  run-slave.sh wait    ◄──  JSON（阻塞至终态后返回，无需多次轮询）
```

`run-slave.sh wait` 在网关侧以递增 backoff（5s→30s）轮询本机 JSON，等 status 到达 `done|partial|failed` 后 `cat` 返回。Master 只需 **一次 SSH 调用**，无需多次轮询。

Master 将最新 poll 缓存在 `var/agent-jobs/<job_id>.last.json`。

---

## 简化：部署

```mermaid
flowchart LR
  subgraph Repo["代码仓库"]
    DA[deploy-all.sh]
    DM[deploy-master.sh]
    DS[deploy-slave.sh]
  end

  subgraph MasterHost["Master 主机"]
    MOC[master-agent.md]
    MJ[submit.sh / poll-wait.sh]
  end

  subgraph Cn1["Slave 网关 cn1"]
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
./scripts/deploy/deploy-all.sh cn1          # Master（本机）+ Slave（cn1）
./scripts/deploy/deploy-master.sh           # 仅 Master
./scripts/deploy/deploy-slave.sh cn1        # 仅 Slave
```

| 端 | OpenCode 默认 agent |
|----|---------------------|
| Master | `master-agent` |
| Slave（cn1） | `slave-agent` |

---

## 委托模式

```mermaid
sequenceDiagram
  participant User as 用户
  participant MA as Master Agent
  participant SS as submit.sh
  participant PS as poll-wait.sh
  participant RS as run-slave.sh (cn1)
  participant Exec as _worker / Slave Agent
  participant Node as cn1..cn10

  User->>MA: 分区任务
  alt Script 模式 (--command)
    MA->>SS: submit --command 'hostname -s'
    SS->>RS: SSH submit
    RS->>Exec: _worker
    Exec->>Node: preflight + exec
    Exec->>RS: 写入 partition_report
  else Agent 模式 (--prompt, agent-to-agent)
    MA->>SS: submit --prompt '检查主机名'
    SS->>RS: SSH submit
    RS->>Exec: _agent_worker
    Exec->>Exec: opencode run --agent slave-agent
    Exec->>RS: 可嵌套 run-slave.sh --command
    RS->>Node: preflight + exec
    Exec->>RS: AGENT_STATUS + PARTITION_REPORT 契约
    RS->>RS: 解析为 partition_report
  end
  MA->>PS: poll-wait --job-id（单次阻塞，SSH → run-slave.sh wait）
  PS->>RS: SSH wait
  RS-->>PS: job JSON（终态）
  MA->>User: 呈现 partition_report.markdown
```

| 模式 | 参数 | 网关执行者 | 适用场景 |
|------|------|------------|----------|
| **Script** | `--command '<cmd>'` | `_worker`（确定性） | 命令明确；快路径 |
| **Agent** | `--prompt '<task>'` | Slave agent LLM | 需判断、诊断、多步骤 |

两种模式产出相同的 `partition_report`；Master 汇报流程一致。

---

## 运行时选择（Slave，仅 agent 模式）

Agent 模式始终使用 OpenCode：`opencode run --agent slave-agent`。

`slave/config/slave.conf` 配置：

```ini
agent_opencode_bin opencode
agent_opencode_agent slave-agent
```

---

## 职责边界

| 层级 | 负责 | 不负责 |
|------|------|--------|
| **Master Agent** | 提交到网关、轮询、呈现 `partition_report.markdown` | SSH/执行 cn2–cn10；从 `nodes.*` 自行拼报告 |
| **Slave 网关** | preflight、节点排除、执行、集中报告 | 越权操作其他分区 |
| **Script 模式** | 确定性 per-node 执行 | LLM 推理 |
| **Agent 模式** | Slave LLM 规划与汇报 | 与 script 同速 |

---

## 文件映射

```
Master（工作区）                      Slave 网关（cn1）
────────────────────────────────────────────────────────────────
master/.opencode/agents/master-agent.md （仅 Master）
opencode.json (master-agent)
master/config/{master,partitions,slaves}.conf
master/scripts/{submit,poll,poll-wait,list-slaves}

slave/              →   经 deploy-slave.sh 部署为扁平 /home/smt/agents/
  .opencode/        →   .opencode/
  opencode.json     →   opencode.json
  config/slave.conf →   config/slave.conf
  (from Master) partitions.conf → config/partitions.conf
  scripts/run-slave.sh → scripts/run-slave.sh
  scripts/resolve-partition.py → scripts/resolve-partition.py
  scripts/preflight/   → scripts/preflight/

master/scripts/submit.sh      SSH →    （仅 Master）
master/scripts/poll-wait.sh  SSH →    scripts/run-slave.sh wait（阻塞至终态）
                                     scripts/run-slave.sh submit / _worker / _agent_worker
var/agent-jobs/*.last.json  ←──      /home/smt/agents/var/agent-jobs/*.json
```

---

## 配置路由（test 分区）

| 文件 | 示例 | 作用 |
|------|------|------|
| `master/config/partitions.conf` | `test cn[1-10]` | 逻辑分区 → 节点集（SoT；部署到网关） |
| `master/config/slaves.conf` | `cn1 test cn[1-10]` | 网关注册表（仅 Master） |
| `master/config/master.conf` | `default_gateway cn1` | Master 默认与轮询策略 |
| `slave/config/slave.conf` | `agent_opencode_bin opencode` | 排除策略 + agent CLI |

```bash
./master/scripts/list-slaves.py --partition test   # → cn1
```

---

## 一句话总结

**Master 只跟网关通信；网关（Slave agent 或确定性 worker）拥有整个分区并返回一份 `partition_report` —— script 与 agent 模式共用同一套 job JSON 与 poll 协议。**
