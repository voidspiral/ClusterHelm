# 集群 Agent 控制面（中文说明）

Master / Slave 双角色：**配置文件定义分区与 Slave 列表，rules 定义行为**。详见 [`config.md`](config.md)。

## 目录结构

```
scripts/jobs/partitions.conf   # 逻辑分区 → 节点集（source of truth）
scripts/jobs/slaves.conf       # Slave 注册表
scripts/jobs/master.conf       # Master 默认与轮询策略
scripts/jobs/list-slaves.py    # 查看管理的 Slave / 路由网关
.cursor/rules/master-agent.mdc
deploy/cn1/.cursor/rules/slave-agent.mdc
docs/zh/config.md              # 配置文件说明
```

## 快速开始

### 1. 部署 Slave 到 cn1

```bash
./scripts/jobs/deploy-slave.sh cn1
```

安装内容：
- `/root/.cursor/rules/slave-agent.mdc`
- `/home/code/agents/scripts/jobs/run-slave.sh`
- `/var/agent-jobs/` 任务目录

### 2. Master 提交 MPI 测试

```bash
./scripts/jobs/submit.sh \
  --partition 'cn1' \
  --command 'mpirun -n 1 --allow-run-as-root hostname'
# 输出：job_id=job-...
```

### 3. 轮询结果

```bash
./scripts/jobs/poll.sh --job-id job-...
```

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

Cursor 实际加载的是 `.mdc` 英文规则；中文文档供团队阅读与运维参考。
