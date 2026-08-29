# MPI 进程监控 Skill — 中文

完整中文版：**[SKILL.zh.md](SKILL.zh.md)**  
英文版（加载）：[SKILL.md](SKILL.md)

## 快速参考

Slave 只提取类型化参数并调用一次确定性 workflow：

```bash
python3 scripts/workflows/workflow_runner.py run mpi-monitor \
  --partition test \
  --arg hosts=cn1,cn2 \
  --arg executable=/path/to/is.S.x \
  --arg ranks_per_node=1 \
  --arg interval=0.1 \
  --arg plot=true \
  --arg raw_output=true
```

- **部署**：Skill → `deploy-slave.sh`；CLI → `deploy-mpi-monitor.sh`（仅网关）
- **作用域**：仅 Slave；Master 用 `submit.sh --prompt` 委托
- **`--match`**：rank 的 comm / argv0（不要 `python3 -c "MARKER=…"`）
- **入口**：`/proc/<pid>`；主命令 `wrap`
- **快速路径**：禁止读包源码或重新选型；workflow 复用父 preflight，完成 probe、
  一次 wrap、采集收尾、绘图与报告
- **任务扩展**：新的任务入口和产物必须增加类型化 workflow 参数或实现，不按作业
  动态生成编排脚本，也不能用 `pidstat` 替代监控后端
- **异常处理**：保留已成功阶段，只重试失败阶段一次；wrap 成功后即使绘图或报告
  失败也禁止重跑 MPI，按完整度返回 `partial`
