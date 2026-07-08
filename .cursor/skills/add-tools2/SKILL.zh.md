---
name: add-tools2-zh
description: >-
  从仓库或工具目录脚手架生成 tool skill（SKILL.md + SKILL.zh.md + reference.md + README.zh.md）。
  用户调用 /add-tools2、要求把工具加入 skills、或从 scripts 目录生成 Slave skill 时使用。
disable-model-invocation: true
---

# 工具转 Skill（`/add-tools2`）

从已有工具目录或仓库路径，生成可部署的 **tool skill**（四文件结构见下）。

## Skill 存放位置（Master vs Slave）

| 类型 | 路径 | 部署 |
|------|------|------|
| **本 meta skill**（`add-tools2`） | `.cursor/skills/add-tools2/` **与** `.opencode/skills/add-tools2/` | 仅 Master，两处保持同步，不 deploy |
| **生成的 tool skill（slave / both）** | `deploy/slave-agent/.cursor/skills/<name>/` + `.opencode/skills/<name>/` | `deploy-slave.sh` |
| **生成的 tool skill（master）** | `.cursor/skills/<name>/` **与** `.opencode/skills/<name>/` | 不 deploy；Master 工作区直接加载 |

**流程：**

1. 在 **Master** 调用 `/add-tools2 <工具路径>` → 写入 `deploy/slave-agent/` 下 skill 文件。
2. 审阅生成物；若需 Slave 路由，更新 `deploy/slave-agent/.opencode/agents/slave-agent.md` skills 表。
3. 执行 `./scripts/jobs/deploy-slave.sh <gateway>`，将 `deploy/slave-agent/.cursor/skills/*` 与 `.opencode/*` 同步到网关 `/home/code/agents/`。

**禁止** 将 `add-tools2` 复制到 `deploy/slave-agent/`。**禁止** 将生成的 tool skill 放在仓库根 `.cursor/skills/`。

英文版：[SKILL.md](SKILL.md)

---

## 输入（缺失时向用户确认）

| 参数 | 示例 | 说明 |
|------|------|------|
| **工具路径** | `scripts/monitor`、`scripts/jobs` | 相对仓库根目录，或绝对路径 |
| **Skill 名称** | `job-runner` | kebab-case；默认目录名转连字符 |
| **作用域** | `slave` / `master` / `both` | **必问用户**（未说明时先问，勿静默假定）。分区/网关工具常选 `slave`；仅本地 Master 脚本选 `master` |
| **独立部署脚本** | `deploy-monitor.sh` | 除 `deploy-slave.sh` 同步 skill 外的可选步骤 |

---

## 发现阶段（写文件前必做）

1. **解析路径** — 必须存在；列出入口脚本（`*.sh`、`*-api.sh`、`*.py`）、README、deploy 脚本。
2. **阅读** 工具目录下 `README.md`（若无则记录并在 skill 中说明）。
3. **追踪集成** — 是否使用 `run-slave.sh`、`submit.sh`、preflight、`partition_report`、`--remote-cmd`？
4. **对照** `deploy/slave-agent/.cursor/skills/` 下已有 skill（结构与语气参考，非硬套某一工具）。
5. **与用户确认** — **作用域（master / slave / both）**、名称、触发词、禁止事项（有歧义或未说明时必问）。

---

## 输出目录（按作用域）

**slave / both（Slave 侧）** — 同时写 Cursor 与 OpenCode：

```
deploy/slave-agent/.cursor/skills/<skill-name>/
deploy/slave-agent/.opencode/skills/<skill-name>/
```

**master** — 仅 Master 工作区：

```
.cursor/skills/<skill-name>/
.opencode/skills/<skill-name>/
├── SKILL.md
├── SKILL.zh.md
├── reference.md
└── README.zh.md
```

**both** — 上述两处都写；`SKILL.md` 用 **角色分工** 区分 Master 命令与 Slave 命令。

生成的 **tool skill** 不要与 **meta skill**（`add-tools2`）混放。**不要** 将 `add-tools2` 放入 `deploy/slave-agent/`。

---

## SKILL.md 建议章节

1. YAML frontmatter（`name`、`description` 第三人称 + 触发词）
2. 标题 + 部署边界（Master / Slave、deploy 脚本）
3. **When to use** / 何时使用
4. **Commands** — 可复制的绝对路径（`/home/code/agents/...`）
5. **Reading output** — JSON/字段表
6. **Reporting to user** — 分区任务需含 `partition_report` 示例
7. **Job flow** — 高层封装 vs 底层调试命令
8. **Forbidden** — 禁止事项
9. **Reference** — 链接 `reference.md`
10. **中文说明** — 链接 `SKILL.zh.md` · `README.zh.md`
11. **角色与运行端**（按用户确认的作用域）：
    - **slave** — 「Master 侧」：`submit.sh` 委托示例；「Slave 侧」：网关命令
    - **master** — Master 本地命令；注明 Slave 不加载
    - **both** — **角色分工** 表 + 两端各自命令

`SKILL.md` 控制在 **500 行以内**；细节放 `reference.md`。

---

## SKILL.zh.md 规则

- frontmatter `name`: `<skill-name>-zh`
- 中文完整镜像操作内容
- 额外章节：**角色分工**、**部署与模拟阶段**、**禁止事项**、**相关文件**（表格）
- 链接英文版：`英文版：[SKILL.md](SKILL.md)`

---

## OpenCode 副本差异

仅在 `.opencode/skills/<skill-name>/SKILL.md` frontmatter 增加：

```yaml
compatibility: opencode
metadata:
  role: {{SCOPE}}   # slave | master | both — 与用户确认一致
  deploy: deploy-slave.sh   # master-only 时可省略 deploy
```

正文与 Cursor 版一致，部署段落注明 `.opencode/skills/` 路径。

---

## 创建后检查清单

- [ ] 已确认作用域（master / slave / both）并与输出路径一致
- [ ] Skill 名 kebab-case，≤64 字符
- [ ] 英文 description 含触发关键词
- [ ] 命令为绝对路径；禁止 SSH 循环等反模式已写明
- [ ] `SKILL.zh.md` 已生成且结构对齐
- [ ] scope 为 master 时：已写入 `.cursor/skills/` 与 `.opencode/skills/` 双份
- [ ] 有结构化输出时 `reference.md` 含 JSON/路径表
- [ ] `README.zh.md` 为短指针（≤30 行）
- [ ] 若需 Slave 路由：更新 `deploy/slave-agent/.opencode/agents/slave-agent.md` skills 表
- [ ] 若 scope 含 slave：提示 `./scripts/jobs/deploy-slave.sh <gateway>`（不部署 `add-tools2`）

---

## 模板

占位符模板见 [reference.md](reference.md) 与 [templates/](templates/)。

---

## 调用示例

```
/add-tools2 scripts/jobs
```

Agent 扫描工具目录 → **向用户确认作用域** → 按 scope 写入对应路径与章节（见上文「输出目录」「角色与运行端」）。
