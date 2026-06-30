# 内存监控 Skill — 中文说明

> **Skill** 经 `deploy-slave.sh` 部署到 `/home/code/agents/.cursor/skills/memory-monitor/`。  
> **mem-api / memmon** 经 `deploy-monitor.sh` 单独部署（可选）。  
> **Master 工作区不加载本 Skill**。

仓库源码：`deploy/slave-agent/.cursor/skills/memory-monitor/`（与 `slave-agent.mdc` 同目录结构）

## 快速参考

```bash
# 本机（网关 cn1）
/home/code/agents/scripts/monitor/mem-api.sh local

# 整个 test 分区
/home/code/agents/scripts/monitor/mem-api.sh partition test

# 子集
/home/code/agents/scripts/monitor/mem-api.sh partition test --subset cn[1-3]
```

在 Slave 网关上执行；`partition` 自动走 `run-slave.sh` 预检与节点排除。分区作业经 `--remote-cmd` 内联采集，**不要求** cn2–cn10 上存在 `memmon.py` 文件（模拟阶段；终态将统一节点接口）。

英文 Skill（Cursor 在网关上加载）：[SKILL.md](SKILL.md)

团队阅读用完整中文文档（仅仓库内，不部署）：`docs/zh/memory-monitor.md`
