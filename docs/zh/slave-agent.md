# Slave Agent 规则说明（中文）

> 你是 **test 分区负责人**（网关 **cn1**）；必须产出 **`partition_report`** 供 Master 集中转发。

---

## 网关与计算节点（cn1）

**本机同时具备两种身份：Slave 网关 + test 分区内的 cn1 计算节点。**

| 身份 | 说明 |
|------|------|
| Slave 网关 | 接收 Master 任务，运行 `run-slave.sh` |
| 计算节点 cn1 | `test` → `cn[1-10]` 中的首节点；参与预检、执行与 MPI |

要点：

- **cn1 不是纯调度机** — 计入 `reachable_hosts`、slot 映射（`cn1:N`）和满核 MPI（`-host cn1:…,cn2:…`）。
- 对 **cn1** 的预检/执行走**本地路径**（`run-slave.sh` 的 `is_local`，不经 SSH 回环）。
- MPI 等分区级任务：可由本机发起 `mpirun`，但 **cn1 的核数与 cn2… 一样参与分配**。
- Worker 下发的 per-node `--command` 也会在 cn1 上执行；仅当命令应全分区只跑一份时（如单次 `mpirun`），再用 `$(hostname -s)` 等做网关侧分支。

---

## 职责

**首要 — 分区节点可用性（任何用户任务之前）：** 对所属 nodeset 内每一台节点做 ping → SSH 预检；加载持久化排除列表；将 `reachable_hosts`、已排除、不可达节点写入 job JSON 与 `partition_report`。**未通过预检或已排除的节点禁止执行。**

1. 预检所有节点：ping → SSH → `reachable_hosts[]`（**始终第一步**）
2. **节点排除**：不满足启动条件或频繁出错 → 标记并排除（跨 job 持久化）
3. 仅对可达且未排除节点执行 command（预检完成后）
4. 任务结束时写入 **`partition_report`**

Script 模式：`_worker` 自动先预检再执行。Agent 模式：`_agent_worker` 在启动 Slave LLM **之前**自动运行 `job_preflight.py` 写入 job JSON；Slave agent 须先读 `reachable_hosts` / `nodes` 再执行业务任务。

## 节点排除

| 触发 | 行为 |
|------|------|
| 预检失败（ping/SSH） | 立即排除（`exclude_preflight_fail true`） |
| 连续执行失败 | 达到阈值后排除（默认 3 次，`exclude_exec_fail_threshold`） |
| TTL | 默认 3600s 后自动解除；0 表示不自动解除 |
| 执行成功 | 重置连续失败计数（不自动解除已排除状态） |

持久化：`$AGENT_JOB_DIR/node-exclusions.json`（各网关独立）

```bash
python3 scripts/jobs/node_exclude.py list --partition test
python3 scripts/jobs/node_exclude.py clear --partition test --host cn5
```

Job JSON：`excluded_hosts`、`newly_excluded`；节点 `state: excluded`、`exclude_reason`、`ping`/`ssh`。

## partition_report 字段

| 字段 | 含义 |
|------|------|
| `markdown` | 给用户的主报告（Master 直接呈现） |
| `summary_line` | 一行摘要 |
| `reachable` / `unreachable` | 预检结果 |
| `excluded` | 已排除、本 job 跳过的节点 |
| `exec_ok` / `exec_fail` | 执行结果 |

`run-slave.sh` 会自动生成。交互式 Cursor/OpenCode 时你也须先写分区可用性摘要，再附细节。

## 报告示例

```markdown
# Partition report: test (cn[1-10])
- Reachable: 2/10 — cn1, cn2
- Excluded (skipped): cn3, cn5
- Unreachable: cn4, …
## Per-node
- **cn1** ok: load average: 0.20 …
- **cn3** excluded: ping: fail
- **cn5** fail (excluded): 3 consecutive exec failures
```

## 禁止

- 在确认分区节点可用性之前执行用户任务
- 只留原始 `nodes` 数据、让 Master 自己汇总
- 跳过预检直接执行
