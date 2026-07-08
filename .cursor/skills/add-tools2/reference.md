# add-tools2 — templates and placeholders

Reference for `/add-tools2` (Master-only meta skill). Example deployed skills live under `deploy/slave-agent/.cursor/skills/`.

## Master vs Slave layout

| Artifact | Path | Notes |
|----------|------|-------|
| Meta skill | `.cursor/skills/add-tools2/` | Never under `deploy/slave-agent/` |
| Generated skill (Cursor) | `deploy/slave-agent/.cursor/skills/<name>/` | Deployed by `deploy-slave.sh` |
| Generated skill (OpenCode) | `deploy/slave-agent/.opencode/skills/<name>/` | Same script |
| Remote (Slave) | `/home/code/agents/.cursor/skills/<name>/` | After deploy |

Deploy command: `./scripts/jobs/deploy-slave.sh <gateway>`

## Placeholder glossary

| Token | Replace with |
|-------|----------------|
| `{{SKILL_NAME}}` | kebab-case id, e.g. `job-runner` |
| `{{TITLE_EN}}` | Human title, e.g. `Memory Monitor (Slave gateway)` |
| `{{TITLE_ZH}}` | 中文标题，如 `内存监控（Slave 网关）` |
| `{{DESCRIPTION_EN}}` | Third-person WHAT + WHEN (≤1024 chars) |
| `{{DESCRIPTION_ZH}}` | 中文 description |
| `{{TOOL_DIR}}` | e.g. `scripts/monitor` |
| `{{ENTRY_SCRIPT}}` | Main CLI, e.g. `mem-api.sh` |
| `{{DEPLOY_SCRIPT}}` | Optional, e.g. `deploy-monitor.sh` or `none` |
| `{{SCOPE}}` | `slave` \| `master` \| `both` |
| `{{DEPLOYMENT_BOUNDARY_PARAGRAPH}}` | Opening paragraph: who loads skill, deploy path (from scope) |
| `{{ROLE_RUNTIME_SECTION}}` | Closing section per scope — see Scope table |
| `{{TRIGGER_BULLETS}}` | When-to-use bullets |
| `{{COMMANDS}}` | Copy-paste command blocks |
| `{{OUTPUT_TABLES}}` | JSON/field tables |
| `{{REPORT_EXAMPLE}}` | partition_report markdown sample |
| `{{FORBIDDEN}}` | Anti-pattern bullets |
| `{{MASTER_DELEGATE}}` | submit.sh example for Master |
| `{{TASK_NAME}}` | `--task` value, usually same as skill name |

## File templates

Skeleton files live in [templates/](templates/):

- `SKILL.md.template` — Cursor English skill
- `SKILL.zh.md.template` — Chinese skill
- `reference.md.template` — JSON/paths reference
- `README.zh.md.template` — Short zh pointer

## Scope → sections & paths

| Scope | Output path | SKILL.md closing section |
|-------|-------------|---------------------------|
| **slave** | `deploy/slave-agent/.cursor/skills/<name>/` (+ OpenCode) | Master: `submit.sh --prompt` delegate; Slave: gateway commands |
| **master** | `.cursor/skills/<name>/` | Master-local commands; Slave does not load |
| **both** | Both paths above | **角色分工** table + split commands |

**Always ask the user** for scope when not specified before writing files.

## Naming

- Directory: `deploy/slave-agent/.cursor/skills/{{SKILL_NAME}}/`
- OpenCode mirror: `deploy/slave-agent/.opencode/skills/{{SKILL_NAME}}/`
- `--task` flag: match `{{SKILL_NAME}}` when job-scoped
- Frontmatter `name`: exactly `{{SKILL_NAME}}` (English SKILL.md); `{{SKILL_NAME}}-zh` (SKILL.zh.md)

## OpenCode frontmatter block

Append to `.opencode/skills/{{SKILL_NAME}}/SKILL.md` frontmatter (after description):

```yaml
compatibility: opencode
metadata:
  role: {{SCOPE}}
  deploy: deploy-slave.sh
```

## Slave agent routing (optional)

When the new skill is user-facing on Slave, add a row to `deploy/slave-agent/.opencode/agents/slave-agent.md`:

```markdown
| `{{SKILL_NAME}}` | {{TRIGGER_SUMMARY}} | Load skill → {{PRIMARY_COMMAND}} |
```

## Validation

Before finishing, skim an existing skill under `deploy/slave-agent/.cursor/skills/` for consistency:

1. Deployment boundary stated in first paragraphs
2. Absolute paths under `/home/code/agents/`
3. Forbidden section present
4. Both zh files exist
5. SKILL.md line count < 500
