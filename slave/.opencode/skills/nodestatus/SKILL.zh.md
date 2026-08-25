---
name: nodestatus-zh
description: >-
  通过 nodestatus 守护进程检查和管理分区内节点状态。适用于节点健康、
  可达性、新鲜度、排除状态、分区摘要、定向 probe 以及明确的排除或清除请求。
compatibility: opencode
metadata:
  role: slave
  deploy: deploy-slave.sh
---

# nodestatus（Slave 网关）

本 Skill 仅通过 `deploy-slave.sh` 部署到 Slave 网关的
`.opencode/skills/nodestatus/`。Master 不加载本 Skill。

`nodestatus` 是分区本地守护进程查询，不是分布式作业。应直接在网关调用
CLI，不要包装为 `workflow_runner.py` 作业。

英文版：[SKILL.md](SKILL.md)

## 角色分工

| 角色 | 使用方式 | 是否加载本 Skill |
|------|----------|------------------|
| Master | 通过 `submit.sh` 委托目标分区 Slave，并转发 `partition_report` | 否 |
| Slave 网关 | 通过本地 Unix socket 查询或管理本分区状态 | 是 |

Master 不应 SSH 扇出到计算节点，也不应自行拼装各节点状态。

## 部署与模拟阶段

| 项目位置 | 部署后位置 | 配置来源 |
|----------|------------|----------|
| `slave/.opencode/skills/nodestatus/` | `.opencode/skills/nodestatus/` | `deploy-slave.sh` |
| `slave/config/slave.conf` | `config/slave.conf` | ClusterHelm |
| `master/config/partitions.conf` | `config/partitions.conf` | Master SoT |
| nodestatus 二进制 | `/usr/local/bin/nodestatus`（默认） | `nodestatus_bin` |

部署由项目现有脚本负责；本 Skill 不复制或生成第二份 gateway 配置。

## 何时使用

- 查询分区或单节点健康、可达性、新鲜度和指标。
- 查看排除节点及排除原因。
- 对 stale/unknown 节点执行定向 probe。
- 用户明确要求排除某一个本分区节点或清除其排除状态。
- 在 `partition_report` 中生成节点状态摘要。

## 运行时配置

运行命令前，从已部署 Slave 配置读取二进制、Unix socket 和超时：

```bash
CONF=config/slave.conf
PARTITIONS=config/partitions.conf
NODESTATUS_BIN="$(awk '$1=="nodestatus_bin"{print $2; exit}' "$CONF")"
NODESTATUS_SOCKET="$(awk '$1=="nodestatus_unix_socket"{print $2; exit}' "$CONF")"
NODESTATUS_TIMEOUT="$(awk '$1=="nodestatus_query_timeout"{print $2; exit}' "$CONF")"
: "${NODESTATUS_BIN:=/usr/local/bin/nodestatus}"
: "${NODESTATUS_SOCKET:=/run/nodestatus/nodestatus.sock}"
: "${NODESTATUS_TIMEOUT:=5}"
```

`PARTITION` 必须来自作业或用户请求上下文，并且存在于 `$PARTITIONS`；禁止猜测分区。

## 命令

分区摘要：

```bash
timeout "$NODESTATUS_TIMEOUT" "$NODESTATUS_BIN" summary \
  --partition "$PARTITION" --socket "$NODESTATUS_SOCKET" -o json
```

完整节点列表：

```bash
timeout "$NODESTATUS_TIMEOUT" "$NODESTATUS_BIN" list \
  --partition "$PARTITION" --socket "$NODESTATUS_SOCKET" -o json
```

定向刷新（仅限本分区节点）：

```bash
timeout "$((NODESTATUS_TIMEOUT + 30))" "$NODESTATUS_BIN" probe \
  --partition "$PARTITION" --hosts "cn2,cn3" \
  --socket "$NODESTATUS_SOCKET" -o json
```

用户明确要求后，排除一个节点：

```bash
timeout "$NODESTATUS_TIMEOUT" "$NODESTATUS_BIN" exclude \
  --partition "$PARTITION" --host "$HOST" --reason "$REASON" \
  --socket "$NODESTATUS_SOCKET" -o json
```

用户明确要求后，清除一个节点的排除状态：

```bash
timeout "$NODESTATUS_TIMEOUT" "$NODESTATUS_BIN" clear \
  --partition "$PARTITION" --host "$HOST" --reason "$REASON" \
  --socket "$NODESTATUS_SOCKET" -o json
```

执行 `exclude` 或 `clear` 后，只运行一次 `list`，核对目标节点的 `state`
与 `exclusion`；不一致时按失败汇报。

## 输出字段

摘要字段：

| 字段 | 含义 |
|------|------|
| `partition` / `generated_at` | 快照所属分区和生成时间 |
| `total` | 配置 nodeset 中节点总数 |
| `states` | online、offline、degraded、excluded、unknown 数量 |
| `fresh` / `stale` | 新鲜窗口内外的节点数量 |
| `sources` | 按 heartbeat/probe 来源统计 |

节点字段：

| 字段 | 含义 |
|------|------|
| `state` | 生效状态；活动排除会覆盖健康状态 |
| `health_state` | 应用排除策略前的健康状态 |
| `fresh` / `last_seen` | 证据是否新鲜以及最后时间 |
| `source` / `diagnostic` | 证据来源和故障说明 |
| `metrics` | CPU、负载、内存、swap、磁盘、I/O、运行时间、核数 |
| `exclusion` | 活动标志、原因、时间及成功/失败计数 |

只有 `fresh=true`、`state=online` 且 `exclusion.excluded` 不为 true 时，
才能把节点视为可立即运行。stale 的 online 结果仍需定向 probe 或正常 preflight。

## 向用户汇报

```markdown
# 节点状态：test（cn[1-3]）
- 快照：2026-07-28T11:00:00Z
- 状态：online 2，excluded 1
- 新鲜：2/3
- 已排除：cn3 — repeated preflight failure

## 节点明细
- **cn1** online，fresh，load1=0.42，mem_avail_mb=8192
- **cn2** online，fresh，load1=0.31，mem_avail_mb=7800
- **cn3** excluded，health=offline — repeated preflight failure
```

必须列出 stale/unknown 节点及诊断信息；排除节点仍计入分区总数。

## 作业流

1. 从作业/请求上下文读取分区，并在 `partitions.conf` 中确认。
2. 从 `slave.conf` 加载运行时值。
3. 汇总问题用 `summary`，节点级问题用 `list`。
4. 仅当状态 stale/unknown 或用户明确要求时使用 `probe`。
5. `exclude/clear` 前确认节点属于当前分区，要求明确请求与原因，只修改一个节点并验证一次。
6. 返回统一的 `partition_report` 风格结果。

守护进程查询失败时，报告 nodestatus 不可用。正常作业 preflight 已具备
ping/SSH 和 legacy 排除投影回退；不要自行编写 SSH 循环重做回退。

## Master 侧（无本 Skill）

```bash
./master/scripts/submit.sh --partition test --prompt \
  '加载 nodestatus，汇总当前节点健康和排除状态，并返回 partition report' \
  --task nodestatus
```

## 禁止事项

- 查询或修改不属于当前 Slave 的分区。
- 批量或自动 `exclude/clear`；每次修改只能针对一个节点。
- 在用户未明确要求或没有具体原因时修改排除状态。
- 把 stale 状态视为节点可运行的证明。
- nodestatus 或正常 preflight 可用时手写 ping/SSH 循环。
- 直接编辑 `node-status*.json` 或 `node-exclusions.json`。
- 调用远程 HTTP 状态接口；应使用本地 Unix socket。

## 相关文件

| 文件 | 说明 |
|------|------|
| `/usr/local/bin/nodestatus` | Slave 运行时 CLI 默认路径 |
| `config/slave.conf` | nodestatus 运行时配置 |
| `config/partitions.conf` | 分区与 nodeset SoT |
| `scripts/preflight/nodestatus_client.py` | preflight 查询/probe 客户端 |
| `scripts/preflight/node_exclude.py` | daemon-first 排除兼容层 |
| `.opencode/skills/nodestatus/SKILL.md` | 英文 Skill |

字段与配置详解：[reference.md](reference.md)
