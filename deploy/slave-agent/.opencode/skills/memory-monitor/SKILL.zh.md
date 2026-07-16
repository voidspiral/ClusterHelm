---
name: memory-monitor-zh
description: >-
  内存监控 Skill 中文说明。Slave 网关上通过 mem-api.sh 监控分区节点内存。
  用户询问 RAM、内存使用率、swap、OOM 风险或分区内存健康时使用。
  仅部署在 Slave 网关，Master 工作区不加载。
---

# 内存监控（Slave 网关）

本 Skill **仅部署在 Slave 网关**（如 cn1），经 `deploy-slave.sh` 同步到 `/home/smt/agents/.opencode/skills/memory-monitor/`。  
监控 CLI（`memmon.py`、`mem-api.sh`）由 **`deploy-monitor.sh`** 单独部署（可选）。  
**Master 工作区不加载本 Skill**；Master 通过 `submit.sh` / `poll-wait.sh` 委托 Slave 执行。

在**网关上**使用 `mem-api.sh`；复用 `run-slave.sh` 的预检、节点排除与作业 JSON。禁止手工 SSH 各节点跑 `free` / `meminfo`。

英文版：[SKILL.md](SKILL.md)

---

## 角色分工

| 角色 | 内存监控方式 | 是否加载本 Skill |
|------|--------------|------------------|
| **Master** | `submit.sh` + `poll-wait.sh`，转发 `partition_report` | **否** |
| **Slave 网关** | `mem-api.sh local` / `partition` | **是** |

Master **禁止** SSH 到计算节点查内存；须提交作业由 Slave 执行。

---

## 部署与模拟阶段

| 位置 | 磁盘是否有 `memmon.py` | 分区采集方式 |
|------|------------------------|--------------|
| cn1 网关 | 有（`deploy-monitor.sh`） | `local` 直接跑文件；`partition` 用 `--remote-cmd` |
| cn2–cn10 | **无**（尚未全节点下发） | 作业 `--command` 为内联命令，不依赖节点文件 |

当前为**模拟调用**：`python3 memmon.py --remote-cmd` 生成 `echo <base64> | base64 -d | python3`，在各可达节点执行。节点需：`python3`、`base64`、`/proc/meminfo`。

`mem-api.sh partition` 已自动使用 `--remote-cmd`，cn2–cn10 无需部署文件。

**后续**：统一节点监控接口 / 全节点安装后，`--command` 可改为各节点固定路径或 HTTP API。详见 `scripts/monitor/README.md`。

部署命令：

```bash
./scripts/jobs/deploy-slave.sh cn1          # rules + skills + run-slave
./scripts/monitor/deploy-monitor.sh cn1     # 可选：mem-api 在网关上
```

---

## 何时使用

- 用户询问内存、RAM、swap、OOM 风险或分区内存健康状况
- 重型 MPI / 批处理任务前检查余量
- 例行分区内存巡检

---

## 命令

### 本机（仅当前节点）

```bash
/home/smt/agents/scripts/monitor/mem-api.sh local
```

返回当前节点单行 JSON（网关 cn1 同时是计算节点）。

### 整个分区

```bash
/home/smt/agents/scripts/monitor/mem-api.sh partition test
```

仅检查子集：

```bash
/home/smt/agents/scripts/monitor/mem-api.sh partition test --subset cn[1-3]
```

内部流程：`run-slave.sh submit`，`--command` 为 `$(python3 memmon.py --remote-cmd)` 的输出 → 对各可达、未排除节点执行 → 轮询至终态 → 聚合 JSON。

---

## 监控原理与系统字段

采集程序 `memmon.py` 读取 Linux **`/proc/meminfo`**（不用 `free` 命令）。

### 直接读取的内核字段

| `/proc/meminfo` | 用途 |
|-----------------|------|
| **MemTotal** | 物理内存总量（kB） |
| **MemAvailable** | 内核估算的可用内存（kB），含可回收 cache |
| **SwapTotal** | Swap 总量（kB） |
| **SwapFree** | Swap 空闲（kB） |

未使用：`MemFree`、`Buffers`、`Cached` 等。

### 派生指标

| 计算 | 说明 |
|------|------|
| `mem_used_kb = MemTotal − MemAvailable` | 已用内存 |
| `mem_used_pct = used / total × 100` | 使用率（1 位小数） |
| `swap_used_kb = SwapTotal − SwapFree` | Swap 已用 |

使用 **MemAvailable** 而非 MemFree，更接近实际还能分配给新程序的内存。

### 输出 JSON 字段

| 字段 | 含义 |
|------|------|
| `host` | 短主机名 |
| `mem_total_mb` | 总内存（MB） |
| `mem_used_mb` | 已用（总量 − 可用） |
| `mem_avail_mb` | 可用于新任务的内存 |
| `mem_used_pct` | 使用百分比 |
| `swap_total_mb` | Swap 总量 |
| `swap_used_mb` | Swap 已用 |

单节点示例：

```json
{"host":"cn1","mem_total_mb":3351,"mem_used_mb":696,"mem_avail_mb":2655,"mem_used_pct":20.8,"swap_total_mb":3862,"swap_used_mb":0}
```

### 分区聚合（`mem-api.sh partition`）

| 顶层字段 | 含义 |
|----------|------|
| `partition` / `job_id` / `status` | 分区、作业 ID、终态 |
| `reachable` | 预检可达节点 |
| `excluded` | 被排除、未采样 |
| `unreachable` | 预检不可达 |
| `nodes` | 各节点 memmon JSON 数组 |
| `parse_errors` | 某节点 stdout 非合法 JSON 时列出 |

---

## 告警建议（仅汇报，MVP 不自动排除）

| `mem_used_pct` | 建议 |
|----------------|------|
| &lt; 85% | 正常 |
| 85%–95% | 警告 — 内存压力偏高 |
| &gt; 95% | 严重 — OOM 风险 |

`mem_avail_mb` 很低且 `swap_used_mb` 偏高时，也应提示警告。

---

## 向用户汇报

`partition` 完成后，按 `partition_report` 风格整理：

```markdown
# 内存报告：test
- 作业：memory-monitor（`job-...`）
- 状态：done
- 可达：8/10 — cn1, cn2, …
- 已排除：cn5
- 不可达：cn9

| 节点 | 使用率 | 可用 MB | Swap 已用 MB |
|------|--------|---------|--------------|
| cn1  | 21.5%  | 2631    | 0            |
| cn2  | 78.2%  | 512     | 128          |

**告警：** cn2 内存使用率 78%（偏高）
```

已排除 / 不可达节点须在文字中说明——它们未被采样。

---

## 作业流

`mem-api.sh partition` 已封装 submit + poll，一般**无需**再单独 poll，除非调试指定 `job_id`。

底层等价（仅调试）：

```bash
/home/smt/agents/scripts/jobs/run-slave.sh submit \
  --partition test \
  --command "$(python3 /home/smt/agents/scripts/monitor/memmon.py --remote-cmd)" \
  --task memory-monitor
/home/smt/agents/scripts/jobs/run-slave.sh poll --job-id <job_id>
```

---

## Master 侧（无本 Skill）

Master 通过 **agent-to-agent** 委托，不下发 `mem-api.sh` 或 `memmon.py`：

```bash
./scripts/jobs/submit.sh --partition test --prompt \
  '检查 test 分区各节点内存与 swap，加载 memory-monitor skill，preflight 后采集，汇总 mem_used_pct 并输出 partition report' \
  --task memory-monitor
./scripts/jobs/poll-wait.sh --job-id <job_id>
```

Slave agent 在网关侧加载本 Skill 并执行 `mem-api.sh partition`（或嵌套 script 作业）。Master 从 `partition_report.markdown` 向用户汇报。

Script 模式回退（仅当用户明确要求 `--command`）：

```bash
CMD=$(python3 scripts/monitor/memmon.py --remote-cmd)
./scripts/jobs/submit.sh --partition test --command "$CMD" --task memory-monitor
```

---

## 禁止事项

- 禁止 SSH 循环各节点跑 `free` 或 ad-hoc awk — 使用 `mem-api.sh partition`
- 禁止跳过预检与节点排除机制
- 禁止对所属分区之外的节点采样
- Master：禁止加载或遵循本 Skill；禁止本地或 SSH 执行分区级 `mem-api.sh`

---

## 相关文件

| 文件 | 说明 |
|------|------|
| `scripts/monitor/memmon.py` | 采集程序 |
| `scripts/monitor/mem-api.sh` | CLI 入口 |
| `scripts/monitor/deploy-monitor.sh` | 网关部署监控脚本 |
| `deploy/slave-agent/.opencode/skills/memory-monitor/SKILL.md` | 英文 Skill |
| `docs/zh/memory-monitor.md` | 团队阅读用中文文档（仓库内，不部署） |

字段详解：[reference.md](reference.md)
