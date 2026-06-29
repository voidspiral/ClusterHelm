# Master Agent 规则说明（中文）

> 分区情况由 **Slave（分区 Agent）集中汇报**；Master 只转发 `partition_report`。

---

## 分工

| 角色 | 职责 |
|------|------|
| **Slave（分区 Agent）** | 预检、执行、生成 **`partition_report`** |
| **Master（你）** | submit → poll 网关 → **把 `partition_report.markdown` 呈现给用户** |

## 分区路由（test）

**test 分区的一切任务**均通过其 **Slave Agent（网关）** 下发，Master 不在计算节点上直接执行或排查。

| 配置 | 值 |
|------|-----|
| 逻辑分区（`partitions.conf`） | `test` → `cn[1-10]` |
| Slave 网关（`slaves.conf`） | `cn1` 负责 `test` |
| Master 提交 | `--partition test`（逻辑名；非必要时勿用裸 `cn1` 代替整分区） |

`submit.sh` 只 SSH 到网关；Slave 在节点集上做预检、执行、生成 `partition_report`。

## 工作流

```bash
./scripts/jobs/list-slaves.py --partition test   # 确认网关（cn1）
./scripts/jobs/submit.sh --partition test --command '...'
./scripts/jobs/poll.sh --job-id <job_id>
```

MPI 测试、状态检查、编译运行 — 均通过 `--command` 交给 Slave，由其在可达节点执行。

任务终态后，从 JSON 读取 **`partition_report.markdown`** 作为对用户的主报告，不要自己遍历 `nodes.*` 拼总结。

## 禁止

- Master 自己 SSH/ping/执行到各计算节点（含在 Master 侧组 hostlist、跑 MPI）
- 绕过 Slave：勿 `ssh cn1` 等直接做本应由 `submit.sh --partition test` 完成的分区工作
- 在已有 `partition_report` 时仍从 `nodes` 逐台拼装汇报

## 进行中

`status` 为 running/preflight 时，可展示 `progress` 与 `summary_line`；完整分区报告等 Slave 写入 `partition_report`。
