# MPI 进程监控 Skill — 中文

完整中文版：**[SKILL.zh.md](SKILL.zh.md)**  
英文版（加载）：[SKILL.md](SKILL.md)

## 快速参考

先探测，未安装则停止（不要 wrap）：

```bash
command -v mpi-monitor || python3 -c "import mpi_monitor" || exit 2
```

```bash
mpi-monitor wrap \
  --hosts cn1,cn2 \
  --match is.S.x \
  --output-dir "${AGENT_JOB_DIR:-/home/cn1/agents/var/agent-jobs}/mpi-monitor" \
  --interval 0.1 \
  -- \
  mpirun -np 2 -hosts cn1,cn2 /path/to/is.S.x

python3 -m mpi_monitor plot --run-dir /path/to/{run_id}
```

- **部署**：Skill → `deploy-slave.sh`；CLI → `deploy-mpi-monitor.sh`（仅网关）。未安装则 skill **直接失败**
- **作用域**：仅 Slave 网关；Master 用 `submit.sh --prompt` 委托
- **数据源 / 入口**：`/proc/<pid>` 的 stat / status / io；主入口 `mpi-monitor wrap`
