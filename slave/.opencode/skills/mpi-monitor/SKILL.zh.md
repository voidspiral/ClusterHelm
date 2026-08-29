---
name: mpi-monitor-zh
description: >-
  在 Slave 网关上用 mpi-monitor 包装 MPI / 任务进程，采集 rank PID 的 CPU、RSS、IO。
  用户要求 wrap mpirun、进程级时序 JSONL 或按进程出 PNG 曲线时使用。
  仅部署在 Slave 网关，Master 工作区不加载。
compatibility: opencode
metadata:
  role: slave
  deploy: deploy-slave.sh
---

# MPI 进程监控（Slave 网关）

本 Skill **仅部署在 Slave 网关**（如 cn1），经 `deploy-slave.sh` 同步到
`$remote_project/.opencode/skills/mpi-monitor/`（`remote_project` 见
`master.conf`，当前为 `/home/cn1/agents`）。

工具 CLI 是独立仓库 **`mpi-monitor`**。Master 用
**`./scripts/deploy/deploy-mpi-monitor.sh cn1`** 部署到网关
（拷到 `$remote_project/vendor/mpi-monitor`，在目录内建 `.venv` 再 `pip install -e .`；
PEP 668 主机禁止对系统 Python `pip install --user`）。
出图：`MPI_MONITOR_PLOT=1`。**不要在 cn2–cnN 上 pip。** `wrap` 经 SSH
下发 inline Python payload，远程节点只需 `python3` 与 `/proc`。
`deploy-slave.sh` **只同步 Skill 文本**，不安装 Python 包。

`mpi-monitor wrap` 是 **网关本地伴生监控**，不是 `workflow_runner.py`
作业，也不是 `run-slave.sh --command` 分区扇出。

**硬门禁（preflight / wrap 之前）：** 用 **bash argv 数组**（或
`scripts/probe-cli.sh`）再 `"${argv[@]}" probe`。未安装则作业 **failed** 并
**立即停止**。禁止 preflight、wrap、`pip install`、SSH 计算节点或编造 series。

**禁止** 把多词命令塞进一个字符串再当路径引用
（`MPI_MON="env PYTHONPATH=… python3 -m mpi_monitor"; "$MPI_MON"` →
`No such file or directory`）。

**Master 工作区不加载本 Skill**；Master 通过 `submit.sh` / `poll-wait.sh`
委托 Slave 执行。

英文版：[SKILL.md](SKILL.md)

---

## 角色分工

| 角色 | 使用方式 | 是否加载本 Skill |
|------|----------|------------------|
| **Master** | `submit.sh` + `poll-wait.sh`，转发 `partition_report` | **否** |
| **Slave 网关** | 先 argv 数组 + `probe`；通过后才 preflight + wrap | **是** |

Master **禁止** SSH 到计算节点跑采集；须提交作业由 Slave 执行。

---

## 部署与模拟阶段

| 位置 | 磁盘上有 `mpi-monitor` 包？ | 采集方式 |
|------|------------------------------|----------|
| cn1 网关（兼计算节点） | **是**（网关 `pip install`） | 本机 hostname / `localhost` 走进程内 collect |
| cn2–cnN | **否**（不要装） | `wrap` SSH inline payload（`setsid` 子壳脱离，不是 `nohup`）→ `/tmp/mpi-monitor/{run_id}/{host}` |

部署命令：

```bash
./scripts/deploy/deploy-slave.sh cn1
./scripts/deploy/deploy-mpi-monitor.sh cn1
# MPI_MONITOR_PLOT=1 ./scripts/deploy/deploy-mpi-monitor.sh cn1   # 可选 PNG
# MPI_MONITOR_SRC=/path/to/mpi-monitor ./scripts/deploy/deploy-mpi-monitor.sh cn1
```

---

## 何时使用

- 用户要看 MPI rank 或匹配二进制的 **进程级** CPU / RSS / IO
- 用户要求用 sidecar **包装** `mpirun` / `mpiexec`
- 用户要 per-PID JSONL 时序，或每进程独立 PNG
- 短作业（NPB class S、亚秒级）需要把 `--interval` 降到 `0.1` / `0.05`
- **不是** 节点 RAM/swap/OOM（用 `memory-monitor`），也不是主机心跳（用 `nodestatus`）

---

## 确定性快速路径

加载本 Skill 即表示监控方案已经确定。直接按下列路径执行，禁止探索式分析：

1. 禁止讨论是否使用 `mpi-monitor` 或改成自定义采样器；固定在网关执行一次
   `wrap`。
2. 将本 Skill 与 [reference.md](reference.md) 视为已安装包的接口契约。**禁止读取
   已安装包的源码**来重复确认 CLI 语法、进程发现、stdout/stderr 继承、路径或
   JSONL 字段。
3. 解析 CLI argv、执行 `probe`、消费已持久化的 nodestatus-first preflight，
   然后计算准确的 `--hosts` 交集。
4. 当任务要求自定义 CSV、组合图、原始输出、汇总或 base64 时，**每个作业重新
   生成作业级编排与后处理脚本**。重新生成属于预期设计；每个脚本按输出契约只
   生成一次，禁止重新评估监控架构。
5. 重定向 `wrap` 的 stdout/stderr 即可捕获被包装程序的完整输出；被包装命令继承
   这些文件描述符，采集器诊断不会替代程序输出。
6. 只执行一次 wrap、一次后处理和一次报告落盘。成功后只检查 `meta.json`、
   `series/`、`charts/` 与本作业生成的产物，禁止回头读取包源码。
7. 大型二进制产物的 `plot_base64_png` 只写入作业 JSON；markdown 仅写路径、
   字节数和 base64 长度，禁止为“是否内联 base64”单独消耗模型轮次。

预期主路径：

```text
probe → 已持久化 preflight → 一次生成脚本 → 一次 wrap
      → 一次后处理 → 一次更新 partition_report → 停止
```

只有真实的非零退出或 usage 错误才能进入诊断，并沿用至多一次重试限制。过程说明
和额外验证不得拆成独立步骤。

---

## 固定控制层，开放任务产物

本 Skill 固定的是监控控制层，而不是任务实现。**允许生成自定义任务产物和任务
入口**，包括循环逻辑、输出收集器、CSV 转换器、组合图和报告构建器。Slave 可
根据任务自由选择语言、结构、文件名与布局，不要求存在任何特定脚本或产物。

如果生成工作负载入口，**生成的任务入口必须作为 `mpi-monitor` 包装的命令**：

```bash
"${argv[@]}" wrap --hosts "$HOSTS" --match "$RANK_BASENAME" \
  --output-dir "$OUT" --interval "$INTERVAL" -- \
  "$TASK_ENTRYPOINT" "${TASK_ARGS[@]}"
```

一次 wrap 可以包住重复启动同一 MPI benchmark 的任务入口；采集器会发现每次
新建的匹配 rank PID。这种自由度不得替换已经选定的监控后端，禁止用 `pidstat`、
`ps` 或临时采样器产出成功结果。它们只能在真实失败后用于定向诊断。

最终 `partition_report` 必须提供后端证据：

- `monitor_backend=mpi-monitor`
- `monitor_run_id`
- `monitor_meta_path`
- `monitor_series_count`

缺少后端证据属于 `contract_error`。自定义产物的名称和内容不属于固定契约。

---

## 确定性异常处理

因采集、绘图、base64 编码或报告落盘失败时，**禁止重新运行已经成功的被包装
命令**。保留所有已完成阶段；下表允许重试时，也只允许对失败阶段定向重试一次。

| 阶段 / reason code | 终态 | 必须执行 | 重试规则 |
|---|---|---|---|
| CLI 硬门 / `hard_gate_failed` | failed | 在 preflight 或 SSH 前写失败报告并停止。 | 禁止 |
| Preflight / `insufficient_hosts` | failed | 列出可达、排除及缺失节点；除非任务明确允许回退，否则不得降低请求节点数。禁止 wrap。 | 本作业内禁止 |
| Wrap / `wrapped_command_failed` | failed | 保留完整 stdout/stderr 及已有 `meta.json`；被包装命令退出码与采集错误分开报告。 | 仅已证实的瞬态 launcher/SSH 错误，或已证实命令尚未启动的 usage 错误可重试一次；应用/benchmark 非零退出禁止重试 |
| 采集 / `collection_incomplete` | partial | 命令成功，但 `collect_errors` 非空或缺少预期 host/PID series。保留原始输出与已有 JSONL，逐项列出缺失数据。 | 禁止重跑命令；只可执行工具明确支持的 fetch/采集收尾，否则直接 partial |
| 后处理 / `postprocess_failed` | partial | 以原始输出、`meta.json`、JSONL 为权威，明确失败的是 CSV、图像还是 base64。 | 重新生成并执行后处理脚本一次；禁止重跑 wrap |
| 报告 / `report_finalize_failed` | 命令结果存在时 partial，否则 failed | 从已有产物重建报告，并保留所有有效文件路径。 | 报告落盘可重试一次；禁止重跑 wrap 或已成功的后处理 |

每个异常报告或 incident sidecar 必须包含 `stage`、`reason_code`、
`retry_allowed`、`attempt`、`message`、`preserved_artifacts`。状态判定：

- `done`：被包装命令成功，且用户要求的监控与报告产物完整；明确为可选的 PNG
  可以缺失，但必须说明。
- `partial`：被包装命令成功，但必需的采集、后处理或报告产物不完整。
- `failed`：硬门/preflight 阻止执行，或被包装应用自身失败。

剩余 deadline 不足以完成允许的重试时，跳过重试并立即报告已保留结果。重试必须
复用同一组节点、命令、run 目录与生成脚本；只有已证实是故障原因的值才能修改。

---

## 命令

### CLI 硬门禁（必须最先执行）

已安装 = PATH 上有 `mpi-monitor`，**或** 网关 venv 二进制存在，**或** 通过
vendor `PYTHONPATH` / 系统 site-packages 能 `import mpi_monitor`。
缺少 matplotlib **不算** 失败（PNG 可选）。
硬门禁用 `"${argv[@]}" probe`，不要用 `--help`。

优先走打包脚本（若 vendor 树里有）：

```bash
VENDOR="${REMOTE_PROJECT:-/home/cn1/agents}/vendor/mpi-monitor"
if [[ -x "$VENDOR/scripts/probe-cli.sh" ]]; then
  MPI_MONITOR_VENDOR="$VENDOR" bash "$VENDOR/scripts/probe-cli.sh" || exit 2
fi
```

否则用 **argv 数组** 再 `probe`：

```bash
VENDOR="${REMOTE_PROJECT:-/home/cn1/agents}/vendor/mpi-monitor"
VENV_BIN="$VENDOR/.venv/bin/mpi-monitor"
argv=()
if command -v mpi-monitor >/dev/null 2>&1; then
  argv=("$(command -v mpi-monitor)")
elif [[ -x "$VENV_BIN" ]]; then
  argv=("$VENV_BIN")
elif PYTHONPATH="$VENDOR/src${PYTHONPATH:+:$PYTHONPATH}" python3 -c "import mpi_monitor" >/dev/null 2>&1; then
  argv=(env "PYTHONPATH=$VENDOR/src${PYTHONPATH:+:$PYTHONPATH}" python3 -m mpi_monitor)
elif python3 -c "import mpi_monitor" >/dev/null 2>&1; then
  argv=(python3 -m mpi_monitor)
else
  echo "mpi-monitor CLI is not installed on this gateway" >&2
  exit 2
fi
"${argv[@]}" probe >/dev/null || exit 2
OUT="${AGENT_JOB_DIR:-/home/cn1/agents/var/agent-jobs}/mpi-monitor"
mkdir -p "$OUT"
```

`exit 2` 后写失败版 `partition_report` 并 **终止**，不得继续作业流。

作业 JSON 是 **平铺兄弟文件**，不要套一层目录：

```bash
"${argv[@]}" job-json
# {AGENT_JOB_DIR}/{AGENT_JOB_ID}.json
# 绝不是 {AGENT_JOB_DIR}/{id}/{id}.json
```

### 主路径 — wrap（`--hosts` 必填）

`--match` 匹配 **rank 可执行文件**（`comm` 或 argv0；shebang 脚本还可匹配 argv1），
**不是** 后面的 argv 子串。不要匹配 `mpirun`。默认 `--interval` 为 `1.0` 秒。
wrap 的退出码等于被包装命令的退出码。

```bash
# HOSTS = 可达 ∩ 本分区所有权 ∩ 任务给出的 MPI 主机列表
"${argv[@]}" wrap \
  --hosts cn1,cn2,cn3 \
  --match is.S.x \
  --output-dir "$OUT" \
  --interval 0.1 \
  -- \
  mpirun -np 2 -ppn 1 -hosts cn1,cn2 -wdir /tmp /path/to/is.S.x
```

本机短主机名和 `localhost` 本地采集；其它主机名走 SSH（`--ssh-user`、`--ssh-identity`）。
远程采集器用 `setsid` 子壳脱离会话（不要用 `nohup`）。

单机多进程：`--hosts "$(hostname -s)"`。

### 仅调试 — collect / plot / remote-cmd

不要作为分区主路径。

```bash
"${argv[@]}" collect --match BIN --output-dir DIR --stop-file FILE --host HOST
"${argv[@]}" plot --run-dir DIR
"${argv[@]}" remote-cmd -- collect --match BIN --output-dir DIR --stop-file FILE --host HOST
```

---

## 输出字段

```text
{output-dir}/{run_id}/
  meta.json
  series/{host}_pid{pid}.jsonl
  charts/{run_id}_{host}_pid{pid}_{cpu|rss|io_read|io_write}.png
```

`meta.json`：`run_id`、`hosts`、`match`、`command`、`interval`、`started_at` /
`ended_at`、`exit_code`、`collect_errors`。

JSONL 每行：`ts`、`host`、`pid`、`cpu_pct`、`rss_mb`、`io_read_bps`、
`io_write_bps`；若有 PMI/PMIx/Open MPI 环境则带 `rank`。

launcher / `ssh` / 采集器 PID 永不采样。`--match` 只出现在后面 argv
（`wrap --match is.S.x`、`mpirun … is.S.x`）时不选中该进程。

无 matplotlib 时仍写 JSONL，跳过 PNG，wrap 仍返回命令退出码。

---

## 向用户汇报

CLI 硬门禁失败时报告 **failed** 并停止（没有 wrap 输出）：

```markdown
# MPI 进程监控: test
- Job: mpi-monitor (`job-…`)
- Status: **failed**
- Reason: 网关 cn1 未安装 `mpi-monitor`
- Action taken: 在 preflight/wrap 之前中止
- Remediation: 仅在 cn1 安装 CLI（`pip install -e /path/to/mpi-monitor`）；不要装到 cn2–cnN
```

wrap 成功后再根据 `meta.json` 与 series/charts 计数合成 `partition_report`，不要贴原始 JSONL。

```markdown
# MPI 进程监控: test
- Job: mpi-monitor (`job-…`)
- Status: done
- Wrap 退出码: 0（被包装命令）
- Run: `20260825T020607Z-59020`
- Hosts: cn1, cn2, cn3（可达 3/3）
- Match: `is.S.x` @ interval 0.1s
- Series: 2 个 JSONL
- Charts: 8 张 PNG（或因无 matplotlib 跳过）

| Host | pid | rank | samples | notes |
|------|-----|------|---------|-------|
| cn1  | 59020 | 0 | 120 | |

**Collect errors:** 无
```

排除/不可达节点写在正文中——它们未进入 `--hosts`。

---

## 作业流

1. **CLI 硬门禁**（argv 数组 + `probe`，或 `probe-cli.sh`）。未安装 → failed
   报告，**停止**。禁止 preflight、wrap、`pip install` 或 `--help`。禁止把多词
   CLI 当单路径引用。
2. 对本分区做 preflight（nodestatus → ping/SSH）。排除/不可达节点不要 wrap。
3. `--hosts` = 可达主机 ∩ 任务中的 MPI 主机列表。禁止编造主机名。
4. 在 **本网关** 执行 **一次** `"${argv[@]}" wrap … -- CMD`。
   wrap 非 0 时 CLI 写入 `$CLUSTERHELM_INCIDENT_PATH` 供 Master 立即可见。
5. 读 `{output-dir}/{run_id}/meta.json`，列出 `series/` 与 `charts/`。
   作业 JSON：`"${argv[@]}" job-json`（平铺文件，不要套目录）。
6. 写一份 `partition_report`。wrap 退出码即 MPI/命令状态。
   wrap 非 0 后至多 **一次** 定向重试，然后必须打印报告契约。禁止无界 Hydra/SSH 排障。

---

## Master 侧（无本 Skill）

```bash
./scripts/submit.sh --partition test --prompt \
  '在 test 分区用 mpi-monitor wrap 包装 MPI 作业：加载 mpi-monitor skill，preflight 后仅在可达节点上 wrap（--hosts 必填，--match 为 rank 二进制 comm/argv0）。采集 CPU/RSS/IO JSONL 与可选 PNG，按契约输出 partition report' \
  --task mpi-monitor
```

---

## 禁止事项

- CLI 硬门禁失败后仍继续（禁止 wrap、pip、SSH、编造 series）
- 把多词 CLI 当单路径引用（`"$MPI_MON"` / 含空格的 `$MPI_MON`）——必须展开 argv 数组
- `import mpi_monitor` 已失败时仍调用 `python3 -m mpi_monitor`
- 省略 `--hosts` 或编造主机列表
- `--match` 去匹配 `mpirun` / `orted` / `ssh` 等 launcher，而不是 rank 二进制
- `--match` 只出现在后面 argv（例如 `python3 -c "MARKER=1; …"`）——必须出现在 comm 或 argv0（或 shebang argv1）
- 打开 `{AGENT_JOB_DIR}/{job_id}/{job_id}.json`（多套一层目录）
- 在本作业里用 `pip install` 自救，或在每台计算节点上 pip——只装网关；远程用 inline payload
- 没有 `--stop-file` 的无限 `collect`（不是常驻 daemon）
- 用 `run-slave.sh --command` 或 `workflow_runner.py` 扇出 `collect`
- 跳过分区 preflight，或在已排除节点上 wrap
- 用本 Skill 查节点 RAM/swap（那是 `memory-monitor`）
- 把多个 PID 叠在同一张 PNG 上（CLI 按 pid × 指标各写一文件）
- wrap 失败后无界 Hydra/SSH/防火墙排障（只允许一次定向重试，然后出报告）
- 用 `mpi-monitor --help` / `wrap --help` 当存活检查，或在第一次 wrap 之前查阅用法
  （仅当真实 wrap 因未知参数失败，或任务明确要求看 usage 时才允许）

---

## 相关文件

| 文件 | 说明 |
|------|------|
| 外部仓库 `mpi-monitor` CLI | 网关 `mpi-monitor` / `python3 -m mpi_monitor` |
| `scripts/probe-cli.sh` | 硬门禁（argv 数组 + `probe`） |
| `mpi-monitor probe` | 硬门禁子命令 |
| `mpi-monitor job-json` | 打印平铺作业 JSON 路径 |
| `slave/.opencode/skills/mpi-monitor/SKILL.md` | 英文 Skill |
| `slave/.opencode/skills/mpi-monitor/reference.md` | JSONL / 路径 |

字段详解：[reference.md](reference.md)
