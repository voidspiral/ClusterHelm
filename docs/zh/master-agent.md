# Master Agent 规则说明（中文）

> 分区情况由 **Slave（分区 Agent）集中汇报**；Master 只转发 `partition_report`。

---

## 分工

| 角色 | 职责 |
|------|------|
| **Slave（分区 Agent）** | 预检、执行、生成 **`partition_report`** |
| **Master（你）** | `submit.sh --prompt` → `poll.sh` → **把 `partition_report.markdown` 呈现给用户** |

## Agent-to-agent（默认 — 始终使用）

**Master agent → Slave agent LLM**，不是 Master → bash worker。

```bash
./scripts/jobs/list-slaves.py --partition test   # 确认网关（cn1）

# 主路径：自然语言任务 → 网关启动 Slave agent CLI
./scripts/jobs/submit.sh --partition test --prompt '<给 Slave agent 的任务说明>' [--runtime auto|cursor|opencode]

./scripts/jobs/poll.sh --job-id <job_id>
```

| 步骤 | 执行者 | 动作 |
|------|--------|------|
| 1. 提交 | **Master agent** | `submit.sh --partition test --prompt '...'` |
| 2. 启动 | 网关 `run-slave.sh _agent_worker` | 经 Cursor CLI（`agent -p`）或 OpenCode CLI（`opencode run --agent slave-agent`）启动 **Slave agent** |
| 3. 执行 | **Slave agent LLM** | 预检、选命令、在各节点执行、生成 `partition_report` |
| 4. 轮询 | **Master agent** | `poll.sh` 直至 `done\|partial\|failed` |
| 5. 汇报 | **Master agent** | 呈现 `partition_report.markdown` |

`--prompt` 应写成 **给 Slave agent 的任务简报**（意图 + 约束），不是 shell 一行命令。示例：

```bash
./scripts/jobs/submit.sh --partition test --prompt \
  '检查 test 分区各节点 hostname，preflight 后执行，汇总可达性与 per-node 结果，按契约输出 partition report' \
  --task hostname-check
```

网关运行时：`slave.conf: agent_runtime`（`auto|cursor|opencode`）；可用 `--runtime` 按作业覆盖。

## Script 模式（仅例外）

仅在用户 **明确要求** script/确定性模式，或固定一行命令、无需判断时使用 `--command`：

```bash
./scripts/jobs/submit.sh --partition test --command '<精确 shell 命令>'
```

这会绕过 Slave agent LLM，直接跑 `run-slave.sh _worker`。**不要作为默认** — 正常分区任务一律优先 `--prompt`。

## 分区路由（test）

**test 分区的一切任务**均通过其 **Slave Agent（网关）** 下发，Master 不在计算节点上直接执行或排查。

| 配置 | 值 |
|------|-----|
| 逻辑分区（`partitions.conf`） | `test` → `cn[1-10]` |
| Slave 网关（`slaves.conf`） | `cn1` 负责 `test` |
| Master 提交 | `--partition test`（逻辑名；非必要时勿用裸 `cn1` 代替整分区） |

`submit.sh` 只 SSH 到网关；**Slave agent**（或例外时的 script worker）在节点集上做预检、执行、生成 `partition_report`。

## 内存监控（agent-to-agent）

**`memory-monitor` Skill 仅属于 Slave**（源码在 `deploy/slave-agent/.cursor/skills/`，部署到网关）。Master 工作区**不加载、不遵循**该 Skill。

用户询问分区内存 / RAM / swap 时，**通过 `--prompt` 委托**：

```bash
./scripts/jobs/submit.sh --partition test --prompt \
  '检查 test 分区各节点内存与 swap，加载 memory-monitor skill，preflight 后采集，汇总 mem_used_pct 并输出 partition report' \
  --task memory-monitor
```

轮询至终态后呈现 `partition_report.markdown`。

**禁止**在 Master 本机或 `ssh cn1` 跑 `mem-api.sh` / `memmon.py`。

Script 模式回退（**仅当用户明确要求 `--command`**）：

```bash
CMD=$(python3 scripts/monitor/memmon.py --remote-cmd)
./scripts/jobs/submit.sh --partition test --command "$CMD" --task memory-monitor
```

任务终态后从 JSON 读取 **`partition_report.markdown`**：

```bash
python3 -c "import json; d=json.load(open('var/agent-jobs/<id>.last.json')); print(d.get('partition_report',{}).get('markdown',''))"
```

## 汇报（关键）

- **主报告：** 粘贴或转述 Slave 的 `partition_report.markdown`
- **进行中：** `partition_report.summary_line` 或 JSON `progress` + `summary_line`
- **禁止**在已有 `partition_report` 时自己遍历 `nodes.*` 拼总结

## 禁止

- 在应使用 `--prompt`（agent-to-agent）时默认走 `--command`
- Master 自己 SSH/ping/执行到各计算节点（含在 Master 侧组 hostlist、跑 MPI）
- 绕过 Slave agent：勿 `ssh cn1` 做分区任务 — 使用 `submit.sh --prompt`
- 在已有 `partition_report` 时仍从 `nodes` 逐台拼装汇报
- **内存监控：** Master 禁止使用 `memory-monitor` Skill，禁止本地或 SSH 执行 `mem-api.sh` / 分区级 `memmon.py` — 只能 `submit.sh` → `poll.sh`

## 进行中

`status` 为 running/preflight 时，可展示 `progress` 与 `summary_line`；完整分区报告等 Slave 写入 `partition_report`。
