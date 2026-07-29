# nodestatus Slave Skill

本目录为 Slave 网关上的节点状态 Skill，运行时部署到：

```text
/home/smt/agents/.opencode/skills/nodestatus/
```

支持：

- `summary` / `list`：查询分区与节点状态
- `probe`：定向刷新 stale/unknown 节点
- `exclude` / `clear`：在用户明确要求时修改一个本分区节点
- 输出统一的 `partition_report` 风格摘要

运行时参数来自 `/home/smt/agents/config/slave.conf`，分区定义来自
`/home/smt/agents/config/partitions.conf`。不要直接修改 nodestatus 或 legacy
排除 JSON 文件。

- 英文操作说明：[SKILL.md](SKILL.md)
- 中文操作说明：[SKILL.zh.md](SKILL.zh.md)
- 字段与配置映射：[reference.md](reference.md)
