# add-tools2 — 中文

完整说明：**[SKILL.zh.md](SKILL.zh.md)**  
英文版（Master 加载）：[SKILL.md](SKILL.md)

## 快速用法（Master 工作区）

```
/add-tools2 scripts/monitor
/add-tools2 /home/code/trans-tools --name trans-tools
```

## 部署流程

```
Master: /add-tools2 → deploy/slave-agent/.cursor/skills/<name>/
                    → deploy/slave-agent/.opencode/skills/<name>/
        ↓ 审阅
        ./scripts/jobs/deploy-slave.sh cn1
        ↓
Slave:  /home/code/agents/.cursor/skills/<name>/
```

- **add-tools2**：仅 `.cursor/skills/add-tools2/`（Master，不 deploy）
- **生成的 skill**：`deploy/slave-agent/` → `deploy-slave.sh` → Slave 网关

已有 skill 可参考：`deploy/slave-agent/.cursor/skills/`
