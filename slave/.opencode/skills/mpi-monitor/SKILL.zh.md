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

**硬门禁（preflight / wrap 之前）：** 在本网关探测 CLI。未安装则作业
**failed** 并 **立即停止**。禁止 preflight、wrap、`pip install`、SSH
计算节点或编造 series。

**Master 工作区不加载本 Skill**；Master 通过 `submit.sh` / `poll-wait.sh`
委托 Slave 执行。

英文版：[SKILL.md](SKILL.md)

---

## 角色分工

| 角色 | 使用方式 | 是否加载本 Skill |
|------|----------|------------------|
| **Master** | `submit.sh` + `poll-wait.sh`，转发 `partition_report` | **否** |
| **Slave 网关** | 先探测 CLI；通过后才 preflight + `mpi-monitor wrap` | **是** |

Master **禁止** SSH 到计算节点跑采集；须提交作业由 Slave 执行。

---

## 部署与模拟阶段

| 位置 | 磁盘上有 `mpi-monitor` 包？ | 采集方式 |
|------|------------------------------|----------|
| cn1 网关（兼计算节点） | **是**（网关 `pip install`） | 本机 hostname / `localhost` 走进程内 collect |
| cn2–cnN | **否**（不要装） | `wrap` SSH inline payload → `/tmp/mpi-monitor/{run_id}/{host}` |

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

## 命令

### CLI 硬门禁（必须最先执行）

已安装 = PATH 上有 `mpi-monitor`，**或** 网关 venv 二进制存在，**或** 通过
vendor `PYTHONPATH` / 系统 site-packages 能 `import mpi_monitor`。
缺少 matplotlib **不算** 失败（PNG 可选）。

```bash
VENDOR="${REMOTE_PROJECT:-/home/cn1/agents}/vendor/mpi-monitor"
VENV_BIN="$VENDOR/.venv/bin/mpi-monitor"
if command -v mpi-monitor >/dev/null 2>&1; then
  MPI_MON=mpi-monitor
elif [[ -x "$VENV_BIN" ]]; then
  MPI_MON="$VENV_BIN"
elif PYTHONPATH="$VENDOR/src${PYTHONPATH:+:$PYTHONPATH}" python3 -c "import mpi_monitor" >/dev/null 2>&1; then
  MPI_MON="env PYTHONPATH=$VENDOR/src python3 -m mpi_monitor"
elif python3 -c "import mpi_monitor" >/dev/null 2>&1; then
  MPI_MON="python3 -m mpi_monitor"
else
  echo "mpi-monitor CLI is not installed on this gateway" >&2
  exit 2
fi
OUT="${AGENT_JOB_DIR:-/home/cn1/agents/var/agent-jobs}/mpi-monitor"
mkdir -p "$OUT"
```

`exit 2` 后写失败版 `partition_report` 并 **终止**，不得继续作业流。

### 主路径 — wrap（`--hosts` 必填）

`--match` 是 `/proc/<pid>/cmdline` 子串，必须指向 **rank 二进制**，不要匹配 `mpirun`。
默认 `--interval` 为 `1.0` 秒。wrap 的退出码等于被包装命令的退出码。

```bash
# HOSTS = 可达 ∩ 本分区所有权 ∩ 任务给出的 MPI 主机列表
$MPI_MON wrap \
  --hosts cn1,cn2,cn3 \
  --match is.S.x \
  --output-dir "$OUT" \
  --interval 0.1 \
  -- \
  mpirun -np 2 -ppn 1 -hosts cn1,cn2 /path/to/is.S.x
```

本机短主机名和 `localhost` 本地采集；其它主机名走 SSH（`--ssh-user`、`--ssh-identity`）。

单机多进程：`--hosts "$(hostname -s)"`。

### 仅调试 — collect / plot / remote-cmd

不要作为分区主路径。

```bash
$MPI_MON collect --match BIN --output-dir DIR --stop-file FILE --host HOST
$MPI_MON plot --run-dir DIR
$MPI_MON remote-cmd -- collect --match BIN --output-dir DIR --stop-file FILE --host HOST
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

1. **CLI 硬门禁**（上一节探测）。未安装 → failed 报告，**停止**。禁止
   preflight、wrap 或 `pip install`。
2. 对本分区做 preflight（nodestatus → ping/SSH）。排除/不可达节点不要 wrap。
3. `--hosts` = 可达主机 ∩ 任务中的 MPI 主机列表。禁止编造主机名。
4. 在 **本网关** 执行 **一次** `mpi-monitor wrap … -- CMD`。
5. 读 `{output-dir}/{run_id}/meta.json`，列出 `series/` 与 `charts/`。
6. 写一份 `partition_report`。wrap 退出码即 MPI/命令状态。

---

## Master 侧（无本 Skill）

```bash
./scripts/submit.sh --partition test --prompt \
  '在 test 分区用 mpi-monitor wrap 包装 MPI 作业：加载 mpi-monitor skill，preflight 后仅在可达节点上 wrap（--hosts 必填，--match 为 rank 二进制）。采集 CPU/RSS/IO JSONL 与可选 PNG，按契约输出 partition report' \
  --task mpi-monitor
```

---

## 禁止事项

- CLI 硬门禁失败后仍继续（禁止 wrap、pip、SSH、编造 series）
- `import mpi_monitor` 已失败时仍调用 `python3 -m mpi_monitor`
- 省略 `--hosts` 或编造主机列表
- `--match` 去匹配 `mpirun` / `orted` 等 launcher，而不是 rank 二进制
- 在本作业里用 `pip install` 自救，或在每台计算节点上 pip——只装网关；远程用 inline payload
- 没有 `--stop-file` 的无限 `collect`（不是常驻 daemon）
- 用 `run-slave.sh --command` 或 `workflow_runner.py` 扇出 `collect`
- 跳过分区 preflight，或在已排除节点上 wrap
- 用本 Skill 查节点 RAM/swap（那是 `memory-monitor`）
- 把多个 PID 叠在同一张 PNG 上（CLI 按 pid × 指标各写一文件）

---

## 相关文件

| 文件 | 说明 |
|------|------|
| 外部仓库 `mpi-monitor` CLI | 网关 `mpi-monitor` / `python3 -m mpi_monitor` |
| `slave/.opencode/skills/mpi-monitor/SKILL.md` | 英文 Skill |
| `slave/.opencode/skills/mpi-monitor/reference.md` | JSONL / 路径 |

字段详解：[reference.md](reference.md)
