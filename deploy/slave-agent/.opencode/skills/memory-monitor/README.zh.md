# 内存监控 Skill — 中文

完整中文版：**[SKILL.zh.md](SKILL.zh.md)**  
英文版（Cursor 加载）：[SKILL.md](SKILL.md)

## 快速参考

```bash
# 本机（网关 cn1）
/home/code/agents/scripts/monitor/mem-api.sh local

# 整个 test 分区
/home/code/agents/scripts/monitor/mem-api.sh partition test

# 子集
/home/code/agents/scripts/monitor/mem-api.sh partition test --subset cn[1-3]
```

- **部署**：Skill → `deploy-slave.sh`；mem-api → `deploy-monitor.sh`（可选）
- **仅 Slave 网关**加载；Master 用 `submit.sh` + `--remote-cmd` 委托
- **数据源**：`/proc/meminfo` 的 `MemTotal`、`MemAvailable`、`SwapTotal`、`SwapFree`

团队文档：`docs/zh/memory-monitor.md`
