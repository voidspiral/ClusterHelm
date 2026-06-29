# Agent 角色描述（中文）

本文档为 Master / Slave 两个 Agent 的**中文角色说明**，对应 Cursor 规则中的 `description` 字段含义，供团队理解与选型使用。

---

## Master Agent（主控 Agent）

**一句话：** 集群编排主控，向 Slave 网关异步下发分区任务，通过轮询收集结果，**绝不**同步阻塞等待远程执行完成。

**适用场景：**
- 向 Slave 网关下发分区任务（负载、MPI、批量命令）
- 轮询 **网关上的 job JSON**，汇总 Slave 已采集的节点结果
- 任何不得由 Master 直接 SSH/ping 各计算节点的场景

**核心职责：**
1. 解析用户目标，用 `list-slaves.py` 选定 **Slave 网关**
2. `submit.sh` 提交（command 由 Slave 在各节点执行），立即得 `job_id`
3. **`poll.sh` 只 SSH 网关**；终态后 **原样呈现 Slave 的 `partition_report.markdown`**
4. **不要**自己遍历 `nodes.*` 拼装分区汇报 — 那是 Slave 的职责

**不应做的事：**
- 在 Master 上循环 `ssh cn1`…`cn10` 或 `ping` 各节点
- 自己跑负载/预检/MPI，而不是交给 Slave 的 `--command`
- 把 poll job 误解为要去轮询 cn[1-10]

**Cursor 规则路径：** `.cursor/rules/master-agent.mdc`（`alwaysApply: true`）

**英文 description（规则内）：**
> Master agent — async cluster orchestration via slave gateways (cn1), submit/poll jobs, never block on remote execution

---

## Slave Agent（从控 Agent）

**一句话：** cn1 网关 Slave，**本身也是 test 分区内的 cn1 计算节点**；管理 **`test`**（`cn[1-10]`），每条指令前 ping+SSH 预检，仅对可达节点执行。

**适用场景：**
- cn1–cn10 分区内批量命令
- 执行前确认哪些节点 ping 通、SSH 可达
- 分区内的 MPI 测试、批量 shell 命令
- 在 cn1 上通过 Cursor CLI 交互式处理本地分区任务

**核心职责：**
1. 接收 job（partition + command + deadline）
2. **Preflight（每条指令前必做）：** ping → SSH，记录可达节点列表 `reachable_hosts`
3. 仅对预检通过的节点执行 command
4. 后台 worker 结束时写入 **`partition_report`**（分区集中汇报）
5. Master 只转发 `partition_report`，不自行汇总节点

**不应做的事：**
- 在一次 `agent -p` 调用里同步跑完 100 节点
- 只在任务结束时才写一次 JSON（必须增量更新）
- 对失败节点无限重试

**Cursor 规则路径：** `~/.cursor/rules/slave-agent.mdc`（cn1，`alwaysApply: true`）

**英文 description（规则内）：**
> Slave agent — partition execution on gateway (cn1), preflight nodes, background jobs, incremental JSON results

---

## 协作关系

```
用户 → Master（本项目）
         │ submit.sh → 仅到 Slave 网关，返回 job_id
         ▼
       cn1 Slave
         │ preflight + exec → cn[1-10]（Master 不参与）
         ▼
       /var/agent-jobs/<job_id>.json（在网关上）
         ▲
         │ poll.sh → 仅 SSH 网关读 JSON（不是逐节点 poll）
       Master → 用户
```

## 何时用哪个 Agent

| 你在哪操作 | 用哪个 | 说明 |
|------------|--------|------|
| 本机 Cursor / WSL 项目 | Master | 编排、提交、轮询、汇总 |
| cn1 网关 SSH / Cursor CLI | Slave | 分区内执行与节点排查 |
| 单节点快速命令 | 直接 SSH 或 Slave 脚本 | 不必走 Master 轮询 |
| 100 节点批量 | Master 只 submit + poll 网关；节点工作全在 Slave |
