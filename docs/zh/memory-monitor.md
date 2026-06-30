# 内存监控 Skill 说明（中文）

> 英文 Skill（部署到 Slave）：`deploy/slave-agent/.cursor/skills/memory-monitor/SKILL.md`  
> **Skill** 经 `deploy-slave.sh` 部署；**mem-api / memmon** 经 `deploy-monitor.sh` 单独部署（可选）。  
> **Master 工作区不加载本 Skill**；Master 通过 `submit.sh` / `poll.sh` 委托 Slave。

---

## 角色分工

| 角色 | 内存监控方式 | Skill |
|------|--------------|-------|
| **Master** | `submit.sh` + `poll.sh`，转发 `partition_report` | **无**（不加载 memory-monitor skill） |
| **Slave 网关** | `mem-api.sh local` / `partition` | **有**（部署在网关项目目录） |

Master **禁止** SSH 到各计算节点手工查内存；须提交作业由 Slave 执行。

---

## 部署与模拟阶段（重要）

| 位置 | 磁盘上是否有 `memmon.py` | 分区采集方式 |
|------|--------------------------|--------------|
| cn1 网关 | `deploy-monitor.sh` 可选安装 | `local` 直接跑文件；`partition` 用 `--remote-cmd` |
| cn2–cn10 | **无**（尚未下发） | 作业 `--command` 为内联命令，不依赖节点上的文件 |

当前为**模拟调用**：`python3 memmon.py --remote-cmd` 生成 `echo <base64> | base64 -d | python3`，在各可达节点执行。节点需具备 `python3`、`base64`、`/proc/meminfo`。

**后续**：统一节点监控接口 / 全节点安装后，可改为各节点固定路径或 HTTP API 调用。详见 `scripts/monitor/README.md`。

---

## Slave 何时使用

- 用户询问内存、RAM、swap、OOM 风险或分区内存状况
- 重型任务前检查余量
- 例行分区内存巡检

## Slave 命令

```bash
/home/code/agents/scripts/monitor/mem-api.sh local
/home/code/agents/scripts/monitor/mem-api.sh partition test
/home/code/agents/scripts/monitor/mem-api.sh partition test --subset cn[1-3]
```

`partition` 内部：`run-slave.sh submit`，`--command` 为 `memmon.py --remote-cmd` 输出（内联，cn2–cn10 无需部署文件）→ 轮询 → 聚合 JSON。

## 输出字段

| 字段 | 含义 |
|------|------|
| `host` | 短主机名 |
| `mem_total_mb` | 总内存（MB） |
| `mem_used_mb` | 已用 |
| `mem_avail_mb` | 可用 |
| `mem_used_pct` | 使用百分比 |
| `swap_total_mb` / `swap_used_mb` | Swap |

### 告警建议（仅汇报）

| `mem_used_pct` | 建议 |
|----------------|------|
| &lt; 85% | 正常 |
| 85%–95% | 警告 |
| &gt; 95% | 严重 — OOM 风险 |

## 向用户汇报示例

```markdown
# 内存报告：test
- 作业：memory-monitor（`job-...`）
- 状态：done
- 可达：8/10 — cn1, cn2, …
- 已排除：cn5

| 节点 | 使用率 | 可用 MB | Swap 已用 MB |
|------|--------|---------|--------------|
| cn1  | 21.5%  | 2631    | 0            |
```

已排除 / 不可达节点须在文字中说明。

## Master 侧（无 Skill）

Master 仅下发作业，例如：

```bash
CMD=$(python3 scripts/monitor/memmon.py --remote-cmd)
./scripts/jobs/submit.sh --partition test --command "$CMD" --task memory-monitor
./scripts/jobs/poll.sh --job-id <job_id>
```

结果从 `partition_report.markdown` 呈现给用户；**不需要** Master 加载 memory-monitor skill。

## 相关文件

| 文件 | 部署方式 |
|------|----------|
| `deploy/slave-agent/.cursor/skills/memory-monitor/*` | `deploy-slave.sh` |
| `scripts/monitor/memmon.py`, `mem-api.sh` | `deploy-monitor.sh`（网关可选） |
| `docs/zh/memory-monitor.md` | 否（仓库内团队文档） |
| `deploy/slave-agent/.cursor/rules/slave-agent.mdc` | `deploy-slave.sh` |

```bash
./scripts/jobs/deploy-slave.sh cn1
./scripts/monitor/deploy-monitor.sh cn1   # 需要 mem-api 时
```

## 禁止事项

- Slave：禁止 SSH 循环节点跑 `free`；禁止对分区外节点采样
- Master：禁止自行组装各节点内存数据；禁止在 Master 工作区依赖本 Skill
