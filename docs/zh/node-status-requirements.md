# 节点状态维护工具 — 需求说明

> 状态：草案（讨论收敛）  
> 相关：ClusterHelm Master / Slave 分区架构；拟通过 `add-tools2` 向 slave-agent 暴露查询接口

## 1. 背景与目标

### 1.1 现状问题

- 每次加载 / 执行任务都对节点做 ping / SSH 扫描，成本高、与业务路径耦合。
- 节点健康多为 job 副作用，缺少持续、可查询的状态面。
- 跨 job 仅持久化排除列表（`node-exclusions.json`），节点恢复依赖 TTL 或手动清除。

### 1.2 目标

在分布式多分区集群中，维护可靠、可查询的节点状态（**存活 + 资源快照**）：

1. 计算节点定期向**本分区网关**汇报状态，避免每次任务全量扫描。
2. 为 slave-agent 提供查询接口，支持可达性判断与后续细粒度调度。
3. 向 Master 提供按分区的状态汇聚视图（Master 不直连计算节点）。

## 2. 架构约束（必须遵守）

| 约束 | 说明 |
|------|------|
| Master 只连网关 | Master 不直接向计算节点收心跳或做分区探测 |
| 分区本地主控 | 心跳 / 状态按分区落在对应 Slave 网关（网关 ≈ 小 Slurmctld） |
| 多分区隔离 | 各网关只处理本分区 nodeset；查询与上报均带 `partition` |
| 配置兼容 | 与 `partitions.conf` / `slaves.conf` / 排除策略 / job JSON 兼容或可联动 |

### 2.1 逻辑拓扑

```text
                    Master（按需拉 summary / 呈现 partition_report）
                         │  SSH（只连网关）
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
    GW-A (partA)    GW-B (partB)    GW-C (partC)
     ▲ ▲ ▲            ▲ ▲            ▲ ▲ ▲
     │ │ │            │ │            │ │ │
    节点定期 Push 心跳 / 指标（仅本分区网关）
```

## 3. 功能需求

### 3.1 状态采集与汇报（计算节点 → 网关）

- 节点侧轻量 agent 定期上报（建议间隔 **10–30s**）。
- 上报内容至少包含：

| 类别 | 字段示例 |
|------|----------|
| 存活 | `host`, `partition`, `ts`, `seq` |
| 资源快照（可演进） | CPU、load、内存、swap、磁盘 / IO 等 |
| 元数据 | `cores`, `agent_version` 等 |

- 网关在超时未收到上报（建议 **3 × interval**）时，将节点标记为 `offline`，并可进入排除流程。
- **Pull 兜底：** 节点未部署 agent 时，网关可通过 ping + SSH 主动 `probe`（兼容现有 preflight）。

### 3.2 网关状态面（Source of Truth）

- 持久化最新状态（建议路径形态：`$AGENT_JOB_DIR/node-status.json`，按 partition 分桶）。
- 节点状态枚举建议：`online | offline | degraded | excluded | unknown`。
- 记录：`last_seen`、freshness、`metrics`、来源（`push` / `probe`）。
- 与排除策略联动：失败累计 / 恢复成功可驱动 exclude / auto-clear（可配置，对齐 `slave.conf` 思路）。
- Job preflight 行为：
  - `fresh + online` → **可跳过**对该节点的全量 ping 扫描；
  - `stale` / `unknown` → 复检或触发 `probe`。

### 3.3 查询接口（slave-agent）

以 **CLI + JSON** 为主（便于 `/add-tools2` 生成 skill）：

| 命令 | 作用 |
|------|------|
| `list` | 查询分区节点详细状态 |
| `summary` | 摘要（计数 + 关键指标） |
| `probe` | 强制刷新探测 |
| `clear` | 解除排除（运维） |

要求：

- 通过 tool skill 暴露给 slave-agent，并在 `slave-agent` 权限中 allow。
- Agent **禁止**手写 ping / SSH 循环扫节点。
- Agent 使用查询结果做可达性判断，并为细粒度调度（如避开高负载节点）提供输入。
- 可选：本机 HTTP `GET /v1/status` 作为加分项；MVP 以 CLI 为准。

### 3.4 汇报给 Master

| 路径 | 说明 | 优先级 |
|------|------|--------|
| 按需拉取 | Master 按 `slaves.conf` SSH 各网关执行 `summary` / `list`，合并缓存 | **主路径** |
| 随任务报告 | slave-agent 将健康摘要写入 `partition_report.markdown` | 辅路径 |

- Master **不接收**原始节点心跳。
- 不作为主路径：节点直连 Master、网关持续向 Master 推原始指标、早期上消息队列。

### 3.5 多分区

- 各网关只接受 / 管理本分区 nodeset 内主机。
- CLI 与上报均带 `--partition`（或从 job 上下文推断）。
- Master 联邦扇出查询，不跨网关直连计算节点。

## 4. 非目标

- **不以 Prometheus 作为控制面 / 调度 SoT**（组件重、Pull 模型与「节点→网关」不完全契合；需要历史大盘 / 告警时可后期旁路导出）。
- 不让 Master 成为全局心跳接收端。
- MVP 不上完整监控中台或消息队列。
- 本工具提供**可调度的事实数据**；细粒度调度策略由 agent（及后续策略层）完成，不在本工具内实现完整调度器。

## 5. 交付与集成

| 项 | 说明 |
|----|------|
| 形态 | 网关 daemon + 节点 agent + CLI；部署优先单二进制（如 Go）或仅标准库的 Python |
| Agent 集成 | Master 调用 `/add-tools2`（scope=`slave`）生成 skill；更新 `slave-agent.md` skill 权限 |
| 部署 | skill 随 `deploy-slave.sh`；二进制 / 节点 agent 可单独 deploy 脚本 |
| 配置 | 扩展 `slave.conf`（间隔、超时、freshness、恢复阈值、store 路径等） |

### 5.1 建议 CLI 形态（示意）

```bash
nodestatus list    --partition test -o json
nodestatus summary --partition test -o json
nodestatus probe   --partition test [--hosts cn2,cn5]
nodestatus clear   --partition test --host cn5
nodestatus serve   # 网关常驻（收心跳 / 周期 probe）
```

### 5.2 查询 JSON 示意

```json
{
  "partition": "test",
  "generated_at": "2026-07-23T07:00:00Z",
  "summary": {
    "online": 2,
    "offline": 1,
    "excluded": 0,
    "total": 3
  },
  "nodes": [
    {
      "host": "cn1",
      "state": "online",
      "last_seen": "2026-07-23T06:59:50Z",
      "fresh": true,
      "source": "push",
      "metrics": {
        "cpu_pct": 12.0,
        "load1": 0.2,
        "mem_avail_mb": 2048
      }
    }
  ]
}
```

## 6. 验收要点

1. 节点定期上报后，新 job 在 freshness 窗口内不再对 `online` 节点做全量 ping 扫描。
2. slave-agent 仅通过 skill / CLI 获取状态，并可写入 `partition_report`。
3. 节点恢复后可按配置自动或半自动脱离排除。
4. Master 能按分区拉取 `summary`，且不直连计算节点。
5. 资源指标字段可逐步增加，schema 保持向前兼容。

## 7. 分期计划

| 阶段 | 内容 |
|------|------|
| **P0** | 网关状态存储 + Pull probe + `list` / `summary` + skill 给 slave-agent；preflight 消费 freshness |
| **P1** | 节点 Push agent（存活 + CPU / 内存 / load）；Master 扇出 `summary` |
| **P2** | IO 等指标、auto-recover、`partition_report` 嵌入 health；可选旁路监控导出 |

## 8. 相关现有组件

| 组件 | 关系 |
|------|------|
| `job_preflight.py` / `run-slave.sh` | 后续消费状态面，减少重复探测 |
| `node_exclude.py` | 排除策略可与状态面联动或逐步由 SoT 驱动 |
| `memory-monitor` skill | 专项内存能力；长期可与同一状态 SoT 对齐 |
| `add-tools2` | 将本工具脚手架为 slave tool skill |
| `slaves.conf` / `partitions.conf` | 分区路由与 nodeset SoT |

## 9. 开放问题（待定）

- [ ] 实现语言：Go 单二进制 vs Python 标准库（以部署便利为准）
- [ ] 传输：HTTP POST vs UDP 心跳
- [ ] `node-status.json` 与 `node-exclusions.json` 合并或主从关系
- [ ] 工具 / skill 正式命名（如 `node-status` / `nodestatus`）
