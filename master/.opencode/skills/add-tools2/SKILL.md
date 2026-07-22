---
name: add-tools2
description: >-
  Scaffold a tool skill from a repo or scripts directory (SKILL.md + SKILL.zh.md +
  reference.md + README.zh.md). Use when the user invokes /add-tools2, asks to add
  a tool to skills, or convert tooling into deployable Slave skills.
disable-model-invocation: true
compatibility: opencode
metadata:
  role: master
---

# Add Tool to Skills (`/add-tools2`)

Scaffold a **tool skill** from an existing tool directory or repo path. Output uses the standard four-file layout under `slave/` (Slave) or `.opencode/skills/` / `.opencode/skills/` (Master).

## Where skills live (Master vs Slave)

| Kind | Path | Deploy |
|------|------|--------|
| **This meta skill** (`add-tools2`) | `.opencode/skills/add-tools2/` **and** `.opencode/skills/add-tools2/` | Master only — keep both in sync; not deployed |
| **Generated tool skill (slave / both)** | `slave/.opencode/skills/<name>/` + `.opencode/skills/<name>/` | `deploy-slave.sh` |
| **Generated tool skill (master)** | `.opencode/skills/<name>/` **and** `.opencode/skills/<name>/` | Not deployed — loaded on Master workspace |

**Workflow:**

1. On **Master**, invoke `/add-tools2 <tool-path>` → agent writes skill files under `slave/` and/or Master skill dirs.
2. Review generated files; update `slave/.opencode/agents/slave-agent.md` skills table if Slave scope.
3. Deploy Slave skills: `./scripts/deploy/deploy-slave.sh <gateway>` (syncs `slave/.opencode/skills/*` and `.opencode/*` to cn1).

Do **not** copy `add-tools2` into `slave/`.

中文说明：[SKILL.zh.md](SKILL.zh.md)

## Inputs (ask if missing)

| Input | Example | Notes |
|-------|---------|-------|
| **Tool path** | ``scripts/monitor`, `master/scripts`, `slave/scripts` | Relative to repo root, or absolute path |
| **Skill name** | `job-runner` | kebab-case; default = dirname with underscores → hyphens |
| **Scope** | `slave` / `master` / `both` | **Ask the user** if not stated — do not assume silently. Partition/gateway tools often `slave`; local Master-only scripts → `master` |
| **Deploy script** | `deploy-monitor.sh`, `deploy-slave.sh` | Optional separate deploy step beyond skills sync |

## Discovery (before writing)

1. **Resolve path** — must exist; list entry scripts (`*.sh`, `*-api.sh`, `*.py`), README, deploy scripts.
2. **Read** `README.md` in the tool dir (create a stub note if absent).
3. **Trace integration** — does it use `run-slave.sh`, `submit.sh`, preflight, `partition_report`, `--remote-cmd`?
4. **Review existing skills** under `slave/.opencode/skills/` for structure and tone (adapt to the tool — do not copy one skill verbatim).
5. **Confirm with user** — **scope (master / slave / both)**, skill name, trigger phrases, forbidden actions — **ask when missing or ambiguous**.

## Output layout (by scope)

**slave / both (Slave side)** — write + OpenCode copies:

```
slave/.opencode/skills/<skill-name>/
slave/.opencode/skills/<skill-name>/
```

**master** — Master workspace (OpenCode):

```
.opencode/skills/<skill-name>/
.opencode/skills/<skill-name>/
├── SKILL.md (+ OpenCode frontmatter on .opencode copy)
├── SKILL.zh.md
├── reference.md
└── README.zh.md
```

**both** — write both locations above; use a **角色分工** / role table to split Master vs Slave commands.

Do **not** mix generated tool skills with the **meta skill** (`add-tools2`). Do **not** copy `add-tools2` into `slave/`.

## SKILL.md sections (required)

1. YAML frontmatter — `name`, `description` (third person, WHAT + WHEN trigger terms)
2. Title + deployment boundary (Master vs Slave, deploy scripts)
3. **When to use** — bullet triggers
4. **Commands** — copy-paste absolute paths under `/home/smt/agents/`
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

## OpenCode copy delta (generated skills)

Add to `.opencode/skills/<skill-name>/SKILL.md` frontmatter:

```yaml
compatibility: opencode
metadata:
  role: slave   # or master / both
  deploy: deploy-slave.sh   # omit for master-only
```

Body matches `SKILL.md`; Slave deploy paragraph notes `.opencode/skills/` under `slave/`.

## Post-create checklist

- [ ] Scope confirmed (master / slave / both) and matches output paths
- [ ] Skill name is kebab-case, ≤64 chars
- [ ] Description includes trigger terms (English)
- [ ] Commands use absolute paths; no manual SSH anti-patterns documented
- [ ] `SKILL.zh.md` present and structurally aligned
- [ ] Master scope: both `.opencode/skills/` and `.opencode/skills/` copies written
- [ ] `reference.md` has JSON/path tables when tool emits structured output
- [ ] `README.zh.md` is a short pointer (≤30 lines)
- [ ] If new skill should appear in Slave agent routing: update `slave/.opencode/agents/slave-agent.md` skills table
- [ ] If scope includes slave: tell user to run `./scripts/deploy/deploy-slave.sh <gateway>` (does not deploy `add-tools2`)

## Templates

Copy and fill placeholders from [reference.md](reference.md) and [templates/](templates/).

## Example invocation

```
/add-tools2 master/scripts
```

Agent scans the tool directory → **asks the user for scope** → writes files to the matching paths and sections (see **Output layout** and **Role & runtime** above).
