# 集群 Agent 控制面（中文说明）

Master / Slave 双角色异步分区执行控制面，支持 **OpenCode** agent 运行时。

**配置文件定义分区与 Slave 列表；agent 规则与 skills 定义行为。** 详见 [`config.md`](config.md)、[`architecture.md`](architecture.md)。

## 目录结构

```
master/
  .opencode/agents/master-agent.md   # Master agent（OpenCode）
  .opencode/skills/                  # Master skills（如 add-tools2）
  opencode.json                      # default_agent=master-agent
  config/
    master.conf                      # Master 默认与 SSH 超时
    partitions.conf                  # SoT：逻辑分区 → 节点集
    slaves.conf                      # SoT：Slave 注册表
  scripts/                           # submit / poll / poll-wait / list-slaves

slave/
  .opencode/agents/slave-agent.md    # Slave agent（OpenCode，部署源码）
  .opencode/skills/                  # Slave skills（如 memory-monitor）
  opencode.json                      # default_agent=slave-agent
  config/slave.conf                  # 节点排除 + agent_opencode_bin
  scripts/run-slave.sh
  scripts/resolve-partition.py       # 读部署自 Master 的 config/partitions.conf
  scripts/preflight/                 # job_preflight.py, node_exclude.py

scripts/deploy/                      # deploy-master / deploy-slave / deploy-all
scripts/monitor/                     # 内存监控工具（可选）
scripts/mpi/

var/agent-jobs/
docs/zh/config.md                    # 配置文件说明
```

## Agent 运行时

| 运行时 | Master | Slave（网关） |
|--------|--------|---------------|
| **OpenCode** | `.opencode/agents/master-agent.md` | `.opencode/agents/slave-agent.md` + skills |

网关 `slave.conf: agent_opencode_bin` 指定 OpenCode CLI。

## 部署（同步 Master + Slave）

| 脚本 | 目标 | 安装内容 |
|------|------|----------|
| `deploy-master.sh [HOST\|local]` | Master（默认本工作区） | OpenCode agent + `opencode.json`，`submit.sh` / `poll-wait.sh` / `master.conf` |
| `deploy-slave.sh <gateway>` | Slave 网关（如 `cn1`） | OpenCode agents/skills + `opencode.json`，`run-slave.sh` / `slave.conf`，`/home/smt/agents/var/agent-jobs/` |
| `deploy-all.sh <gateway> [master-host]` | 两端一起 | 依次执行 `deploy-master.sh` 和 `deploy-slave.sh` |

```bash
# 两端一起部署（Master 本机 + Slave cn1）
./scripts/deploy/deploy-all.sh cn1

# 或分开部署
./scripts/deploy/deploy-master.sh                # 本机 Master
./scripts/deploy/deploy-master.sh <master-host>  # 远程 Master（SSH）
./scripts/deploy/deploy-slave.sh cn1             # Slave 网关

# 可选：网关内存监控 CLI
./scripts/monitor/deploy-monitor.sh cn1
```

部署后，两端各自使用对应的 OpenCode 默认 agent：

| 节点 | `opencode.json` | OpenCode agent |
|------|-----------------|----------------|
| Master | `default_agent: master-agent` | `master/.opencode/agents/master-agent.md` |
| Slave（cn1） | `default_agent: slave-agent` | `slave/.opencode/agents/slave-agent.md` |

## 快速开始

### 1. 部署并同步

```bash
./scripts/deploy/deploy-all.sh cn1
```

`deploy-slave.sh` 额外安装：
- `/home/smt/agents/.opencode/skills/`（Slave 侧 tool skills，如 `memory-monitor`）
- `/home/smt/agents/var/agent-jobs/` 任务目录

内存监控脚本（`memmon.py`、`mem-api.sh`）由 **`deploy-monitor.sh`** 单独部署，不属于 Slave agent 本体。

### 2. 提交任务

```bash
# Agent 模式（Master 默认）：agent-to-agent，网关启动 Slave agent LLM
./master/scripts/submit.sh --partition test --prompt '检查各节点主机名并汇总报告'
# 输出：job_id=job-...

# Script 模式（仅例外）：用户明确要求确定性命令时
./master/scripts/submit.sh --partition test --command 'hostname -s'
```

### 3. 等待结果

```bash
# 单次阻塞等待（SSH → run-slave.sh wait，终态后返回）
./master/scripts/poll-wait.sh --job-id job-...
```

## 委托模式

| 模式 | 参数 | 网关执行者 |
|------|------|------------|
| Script | `--command '<cmd>'` | 确定性 worker（`run-slave.sh _worker`）：preflight → exec → `partition_report` |
| Agent | `--prompt '<task>'` | **Slave agent LLM**（OpenCode CLI）；运行时由 `slave.conf: agent_opencode_bin` 指定 |

Agent 模式与 Script 模式共用同一套 job JSON 与轮询；agent 最终输出需遵循报告契约（`AGENT_STATUS` + `===PARTITION_REPORT_BEGIN/END===`），由网关解析为 `partition_report`。

## 设计原则

| 原则 | 说明 |
|------|------|
| 异步提交 | Master 只下发任务，立即拿到 `job_id` |
| 单次阻塞等待 | `poll-wait.sh` 通过 `run-slave.sh wait` 在网关侧阻塞轮询，仅需一次 SSH 调用 |
| 增量进度 | Slave 逐节点更新 JSON，网关侧 `last.json` 实时反映进度 |
| 故障隔离 | 单节点失败不拖垮整批任务 |

## Agent 定义对照

| 角色 | OpenCode | 中文文档 |
|------|----------|----------|
| Master | `master/.opencode/agents/master-agent.md` | `docs/zh/master-agent.md` |
| Slave | `slave/.opencode/agents/slave-agent.md` | `docs/zh/slave-agent.md` |
| Skill：内存监控 | `slave/.opencode/skills/memory-monitor/`（**仅 Slave 网关**） | `SKILL.zh.md` / `docs/zh/memory-monitor.md` |
| Skill：add-tools2 | `master/.opencode/skills/add-tools2/`（**仅 Master**） | `SKILL.zh.md` |

运行时加载 OpenCode agent 定义；中文文档供团队阅读与运维参考。
