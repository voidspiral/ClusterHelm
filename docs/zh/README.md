# 集群 Agent 控制面（中文说明）

Master / Slave 双角色：**配置文件定义分区与 Slave 列表，rules 定义行为**。详见 [`config.md`](config.md)、[`architecture.md`](architecture.md)。

## 目录结构

```
.cursor/rules/master-agent.mdc          # Master Cursor 规则（源码）
.opencode/agents/master-agent.md        # Master OpenCode agent
opencode.json                           # default_agent=master-agent

deploy/slave-agent/
  .cursor/rules/slave-agent.mdc         # Slave Cursor 规则（部署源码）
  .opencode/agents/slave-agent.md       # Slave OpenCode agent（部署源码）
  opencode.json                         # default_agent=slave-agent

scripts/jobs/
  partitions.conf   # 逻辑分区 → 节点集（source of truth）
  slaves.conf       # Slave 注册表
  master.conf       # Master 默认与轮询策略
  slave.conf        # 节点排除 + agent_runtime（cursor/opencode）
  deploy-master.sh  # 部署 Master agent（本机或远程）
  deploy-slave.sh   # 部署 Slave agent 到网关
  deploy-all.sh     # 一次部署 Master + Slave
  list-slaves.py    # 查看管理的 Slave / 路由网关
docs/zh/config.md   # 配置文件说明
```

## 部署（同步 Master + Slave）

| 脚本 | 目标 | 安装内容 |
|------|------|----------|
| `deploy-master.sh [HOST\|local]` | Master（默认本工作区） | `master-agent.mdc` → `~/.cursor/rules/`，`.opencode/agents/master-agent.md`，`opencode.json`，`submit.sh` / `poll.sh` / `master.conf` |
| `deploy-slave.sh <gateway>` | Slave 网关（如 `cn1`） | `slave-agent.mdc` → `~/.cursor/rules/`，`.opencode/`（agents + skills），`opencode.json`，`run-slave.sh` / `slave.conf`，`/var/agent-jobs/` |
| `deploy-all.sh <gateway> [master-host]` | 两端一起 | 依次执行 `deploy-master.sh` 和 `deploy-slave.sh` |

```bash
# 两端一起部署（Master 本机 + Slave cn1）
./scripts/jobs/deploy-all.sh cn1

# 或分开部署
./scripts/jobs/deploy-master.sh                # 本机 Master
./scripts/jobs/deploy-master.sh <master-host>  # 远程 Master（SSH）
./scripts/jobs/deploy-slave.sh cn1             # Slave 网关

# 可选：网关内存监控 CLI
./scripts/monitor/deploy-monitor.sh cn1
```

部署后，两端各自使用对应的 OpenCode 默认 agent：

| 节点 | `opencode.json` | OpenCode agent |
|------|-----------------|----------------|
| Master | `default_agent: master-agent` | `.opencode/agents/master-agent.md` |
| Slave（cn1） | `default_agent: slave-agent` | `deploy/slave-agent/.opencode/agents/slave-agent.md` |

## 快速开始

### 1. 部署并同步

```bash
./scripts/jobs/deploy-all.sh cn1
```

`deploy-slave.sh` 额外安装：
- `/home/code/agents/.cursor/skills/`（如 `memory-monitor`）
- `/var/agent-jobs/` 任务目录

内存监控脚本（`memmon.py`、`mem-api.sh`）由 **`deploy-monitor.sh`** 单独部署，不属于 Slave agent 本体。

### 2. 提交任务

```bash
# Script 模式：确定性命令
./scripts/jobs/submit.sh --partition test --command 'hostname -s'

# Agent 模式：agent-to-agent，网关启动 Slave agent LLM
./scripts/jobs/submit.sh --partition test --prompt '检查各节点主机名并汇总报告'
# 输出：job_id=job-...
```

### 3. 轮询结果

```bash
./scripts/jobs/poll.sh --job-id job-...
```

## 委托模式

| 模式 | 参数 | 网关执行者 |
|------|------|------------|
| Script | `--command '<cmd>'` | 确定性 worker（`run-slave.sh _worker`）：preflight → exec → `partition_report` |
| Agent | `--prompt '<task>'` | **Slave agent LLM**，由 Cursor CLI（`agent -p`）或 OpenCode CLI（`opencode run --agent slave-agent`）启动；运行时由网关 `slave.conf: agent_runtime` 决定（`auto\|cursor\|opencode`，可用 `--runtime` 覆盖） |

Agent 模式与 Script 模式共用同一套 job JSON 与轮询；agent 最终输出需遵循报告契约（`AGENT_STATUS` + `===PARTITION_REPORT_BEGIN/END===`），由网关解析为 `partition_report`。

## 设计原则

| 原则 | 说明 |
|------|------|
| 异步提交 | Master 只下发任务，立即拿到 `job_id` |
| 短连接轮询 | 每次 poll 应在秒级返回，不长时间挂 SSH |
| 增量进度 | Slave 逐节点更新 JSON，Master 可汇报部分结果 |
| 故障隔离 | 单节点失败不拖垮整批任务 |

## 规则文件对照

| 角色 | Cursor 规则（英文） | 中文文档 |
|------|---------------------|----------|
| Master | `.cursor/rules/master-agent.mdc` | `docs/zh/master-agent.md` |
| Slave | `~/.cursor/rules/slave-agent.mdc`（cn1） | `docs/zh/slave-agent.md` |
| Skill：内存监控 | `deploy/slave-agent/.cursor/skills/memory-monitor/SKILL.md`（**仅部署到 Slave 网关**） | `SKILL.zh.md` / `docs/zh/memory-monitor.md` |

Cursor 实际加载的是 `.mdc` 英文规则；中文文档供团队阅读与运维参考。
