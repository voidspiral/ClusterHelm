# 内存监控 Skill 说明（中文）

> **完整 Skill 中文版：** [`deploy/slave-agent/.cursor/skills/memory-monitor/SKILL.zh.md`](../deploy/slave-agent/.cursor/skills/memory-monitor/SKILL.zh.md)  
> 英文 Skill（部署到 Slave）：[`SKILL.md`](../deploy/slave-agent/.cursor/skills/memory-monitor/SKILL.md)

**Skill** 经 `deploy-slave.sh` 部署；**mem-api / memmon** 经 `deploy-monitor.sh` 单独部署（可选）。  
**Master 工作区不加载本 Skill**；Master 通过 `submit.sh` / `poll.sh` 委托 Slave。

---

## 角色分工

| 角色 | 内存监控方式 | Skill |
|------|--------------|-------|
| **Master** | `submit.sh` + `poll.sh`，转发 `partition_report` | **无** |
| **Slave 网关** | `mem-api.sh local` / `partition` | **有** |

---

## 监控哪些系统字段

`memmon.py` 读取 **`/proc/meminfo`**：

| 内核字段 | 输出 |
|----------|------|
| `MemTotal` | `mem_total_mb` |
| `MemAvailable` | `mem_avail_mb` |
| 派生：`Total − Available` | `mem_used_mb`、`mem_used_pct` |
| `SwapTotal` / `SwapFree` | `swap_total_mb` / `swap_used_mb` |

选用 `MemAvailable`（非 `MemFree`），更接近实际可分配内存。

---

## Slave 命令

```bash
/home/code/agents/scripts/monitor/mem-api.sh local
/home/code/agents/scripts/monitor/mem-api.sh partition test
/home/code/agents/scripts/monitor/mem-api.sh partition test --subset cn[1-3]
```

分区作业经 `memmon.py --remote-cmd` 内联执行，cn2–cn10 无需部署文件（模拟阶段）。

---

## Master 委托（无 Skill）

```bash
CMD=$(python3 scripts/monitor/memmon.py --remote-cmd)
./scripts/jobs/submit.sh --partition test --command "$CMD" --task memory-monitor
./scripts/jobs/poll.sh --job-id <job_id>
```

---

## 部署

```bash
./scripts/jobs/deploy-slave.sh cn1
./scripts/monitor/deploy-monitor.sh cn1   # 需要 mem-api 时
```

---

## 汇报示例

```markdown
# 内存报告：test
- 作业：memory-monitor（`job-...`）
- 状态：done
- 可达：8/10 — cn1, cn2, …

| 节点 | 使用率 | 可用 MB | Swap 已用 MB |
|------|--------|---------|--------------|
| cn1  | 21.5%  | 2631    | 0            |
```

告警参考：`mem_used_pct` &lt; 85% 正常，85–95% 警告，&gt; 95% 严重。

详细说明见 **[SKILL.zh.md](../deploy/slave-agent/.cursor/skills/memory-monitor/SKILL.zh.md)**。
