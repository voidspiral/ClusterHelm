---
name: add-tools2
description: >-
  Scaffold a tool skill from a repo or scripts directory (SKILL.md + SKILL.zh.md +
  reference.md + README.zh.md). Use when the user invokes /add-tools2, asks to add
  a tool to skills, or convert tooling into deployable Slave skills.
disable-model-invocation: true
---

# Add Tool to Skills (`/add-tools2`)

Scaffold a **tool skill** from an existing tool directory or repo path. Output uses the standard four-file layout under `deploy/slave-agent/`.

## Where skills live (Master vs Slave)

| Kind | Path | Deploy |
|------|------|--------|
| **This meta skill** (`add-tools2`) | `.cursor/skills/add-tools2/` | Master only — not deployed |
| **Generated tool skill (slave / both)** | `deploy/slave-agent/.cursor/skills/<name>/` + `.opencode/skills/<name>/` | `deploy-slave.sh` |
| **Generated tool skill (master)** | `.cursor/skills/<name>/` | Not deployed — loaded on Master workspace |

**Workflow:**

1. On **Master**, invoke `/add-tools2 <tool-path>` → agent writes skill files under `deploy/slave-agent/`.
2. Review generated files; update `deploy/slave-agent/.opencode/agents/slave-agent.md` skills table if needed.
3. Deploy to Slave gateway: `./scripts/jobs/deploy-slave.sh <gateway>` (syncs `deploy/slave-agent/.cursor/skills/*` and `.opencode/*` to `/home/code/agents/` on cn1).

Do **not** copy `add-tools2` into `deploy/slave-agent/`. Do **not** put generated tool skills in repo-root `.cursor/skills/`.

中文说明：[SKILL.zh.md](SKILL.zh.md)

## Inputs (ask if missing)

| Input | Example | Notes |
|-------|---------|-------|
| **Tool path** | `scripts/monitor`, `scripts/jobs` | Relative to repo root, or absolute path |
| **Skill name** | `job-runner` | kebab-case; default = dirname with underscores → hyphens |
| **Scope** | `slave` / `master` / `both` | **Ask the user** if not stated — do not assume silently. Partition/gateway tools often `slave`; local Master-only scripts → `master` |
| **Deploy script** | `deploy-monitor.sh`, `deploy-slave.sh` | Optional separate deploy step beyond skills sync |

## Discovery (before writing)

1. **Resolve path** — must exist; list entry scripts (`*.sh`, `*-api.sh`, `*.py`), README, deploy scripts.
2. **Read** `README.md` in the tool dir (create a stub note if absent).
3. **Trace integration** — does it use `run-slave.sh`, `submit.sh`, preflight, `partition_report`, `--remote-cmd`?
4. **Review existing skills** under `deploy/slave-agent/.cursor/skills/` for structure and tone (adapt to the tool — do not copy one skill verbatim).
5. **Confirm with user** — **scope (master / slave / both)**, skill name, trigger phrases, forbidden actions — **ask when missing or ambiguous**.

## Output layout (by scope)

**slave / both (Slave side)** — write Cursor + OpenCode copies:

```
deploy/slave-agent/.cursor/skills/<skill-name>/
deploy/slave-agent/.opencode/skills/<skill-name>/
```

**master** — Master workspace only:

```
.cursor/skills/<skill-name>/
├── SKILL.md
├── SKILL.zh.md
├── reference.md
└── README.zh.md
```

**both** — write both locations above; use a **角色分工** / role table to split Master vs Slave commands.

Do **not** mix generated tool skills with the **meta skill** (`add-tools2`). Do **not** copy `add-tools2` into `deploy/slave-agent/`.

## SKILL.md sections (required)

1. YAML frontmatter — `name`, `description` (third person, WHAT + WHEN trigger terms)
2. Title + deployment boundary (Master vs Slave, deploy scripts)
3. **When to use** — bullet triggers
4. **Commands** — copy-paste absolute paths under `/home/code/agents/`
5. **Reading output** — tables for JSON/fields
6. **Reporting to user** — `partition_report` markdown example if partition-scoped
7. **Job flow** — high-level wrapper vs low-level debug commands
8. **Forbidden** — anti-patterns (SSH loops, skip preflight, etc.)
9. **Reference** — link to `reference.md`
10. **中文说明** — link to `SKILL.zh.md` · `README.zh.md`
11. **Role & runtime** (from user-confirmed scope):
    - **slave** — Master section: `submit.sh` delegate example; Slave section: gateway commands
    - **master** — Master-local commands; note Slave does not load this skill
    - **both** — role table + commands for each side

Keep `SKILL.md` **under 500 lines**. Push detail to `reference.md`.

## SKILL.zh.md rules

- Frontmatter `name`: `<skill-name>-zh`
- Full Chinese mirror of operational content
- Extra sections: **角色分工**, **部署与模拟阶段**, **禁止事项**, **相关文件** (table)
- Link back to English: `英文版：[SKILL.md](SKILL.md)`

## OpenCode copy delta

Add to `.opencode/skills/<skill-name>/SKILL.md` frontmatter only:

```yaml
compatibility: opencode
metadata:
  role: slave   # or master / both
  deploy: deploy-slave.sh
```

Body matches Cursor `SKILL.md` except paths note `.opencode/skills/` in deployment paragraph.

## Post-create checklist

- [ ] Scope confirmed (master / slave / both) and matches output paths
- [ ] Skill name is kebab-case, ≤64 chars
- [ ] Description includes trigger terms (English)
- [ ] Commands use absolute paths; no manual SSH anti-patterns documented
- [ ] `SKILL.zh.md` present and structurally aligned
- [ ] `reference.md` has JSON/path tables when tool emits structured output
- [ ] `README.zh.md` is a short pointer (≤30 lines)
- [ ] If new skill should appear in Slave agent routing: update `deploy/slave-agent/.opencode/agents/slave-agent.md` skills table
- [ ] If scope includes slave: tell user to run `./scripts/jobs/deploy-slave.sh <gateway>` (does not deploy `add-tools2`)

## Templates

Copy and fill placeholders from [reference.md](reference.md) and [templates/](templates/).

## Example invocation

```
/add-tools2 scripts/jobs
```

Agent scans the tool directory → **asks the user for scope** → writes files to the matching paths and sections (see **Output layout** and **Role & runtime** above).
