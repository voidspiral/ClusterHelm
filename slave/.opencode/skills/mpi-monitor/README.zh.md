# MPI 进程监控 Skill — 中文

完整中文版：**[SKILL.zh.md](SKILL.zh.md)**  
英文版（加载）：[SKILL.md](SKILL.md)

## 快速参考

argv 数组 + `probe`，禁止 `"$MPI_MON"`：

```bash
VENDOR="${REMOTE_PROJECT:-/home/cn1/agents}/vendor/mpi-monitor"
# 优先：MPI_MONITOR_VENDOR="$VENDOR" bash "$VENDOR/scripts/probe-cli.sh"
argv=("$VENDOR/.venv/bin/mpi-monitor")
"${argv[@]}" probe || exit 2
"${argv[@]}" job-json   # {AGENT_JOB_DIR}/{id}.json，不要套目录
"${argv[@]}" wrap --hosts cn1,cn2 --match is.S.x \
  --output-dir "${AGENT_JOB_DIR:-/home/cn1/agents/var/agent-jobs}/mpi-monitor" \
  --interval 0.1 -- mpirun -np 2 -hosts cn1,cn2 -wdir /tmp /path/to/is.S.x
```

- **部署**：Skill → `deploy-slave.sh`；CLI → `deploy-mpi-monitor.sh`（仅网关）
- **作用域**：仅 Slave；Master 用 `submit.sh --prompt` 委托
- **`--match`**：rank 的 comm / argv0（不要 `python3 -c "MARKER=…"`）
- **入口**：`/proc/<pid>`；主命令 `wrap`
- **快速路径**：禁止读包源码或重新选型；每个作业按输出契约一次生成脚本、一次
  wrap、一次后处理、一次写报告
- **任务自由度**：允许动态生成任意任务入口与产物，不固定文件名、语言或布局；
  生成的任务入口放在 `mpi-monitor wrap ... --` 后，不能用 `pidstat` 替代监控后端
- **大字段**：`plot_base64_png` 只写结构化 job JSON；markdown 仅写路径与大小
- **异常处理**：保留已成功阶段，只重试失败阶段一次；wrap 成功后即使绘图或报告
  失败也禁止重跑 MPI，按完整度返回 `partial`
