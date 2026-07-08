# add-tools2 — 中文

完整说明：**[SKILL.zh.md](SKILL.zh.md)**  
英文版：[SKILL.md](SKILL.md)

## 快速用法（Master 工作区）

```
/add-tools2 scripts/monitor
/add-tools2 /home/code/trans-tools --name trans-tools
```

## Master 加载路径

| 运行时 | 路径 |
|--------|------|
| Cursor | `.cursor/skills/add-tools2/` |
| OpenCode | `.opencode/skills/add-tools2/` |

两处内容保持同步；**不** deploy 到 Slave。

## 部署流程（生成的 tool skill）

```
Master: /add-tools2 → deploy/slave-agent/...（slave scope）
                    → .cursor/skills/ + .opencode/skills/（master scope）
        ↓ 审阅
        ./scripts/jobs/deploy-slave.sh cn1   # 仅 slave/both
```

已有 skill 可参考：`deploy/slave-agent/.cursor/skills/`
