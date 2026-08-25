## Context

The nodestatus Go binary already runs as a partition-local gateway daemon and
node reporter. ClusterHelm already renders its gateway configuration, deploys
its binary and service, consumes fresh state in preflight, projects exclusions
for rollback, and aggregates summaries on Master. The missing layer is an
explicit Slave-agent skill and a deployment integrity check for that skill.

The Slave is an OpenCode agent deployed from `slave/.opencode`. Its normal
agent-mode tasks use deterministic workflows, but nodestatus operations are
local Unix-socket requests and do not submit work to compute nodes. Runtime
values are split deliberately: logical partition definitions belong to Master,
while binary, socket, timeout, and daemon rendering values live in
`slave.conf`.

## Goals / Non-Goals

**Goals:**

- Give the Slave agent a discoverable, bilingual nodestatus skill.
- Make local status queries deterministic and configuration-aware.
- Permit explicit, bounded `exclude` and `clear` operations without enabling
  autonomous bulk policy changes.
- Preserve nodestatus-first preflight with the existing ping/SSH and legacy
  exclusion fallback.
- Reject incomplete or inconsistent `.opencode` deployment bundles early.

**Non-Goals:**

- Changing the nodestatus binary, API, data model, service deployment, or node
  reporters.
- Adding a distributed workflow wrapper for local daemon calls.
- Deploying a Cursor-specific skill that the Slave runtime does not load.
- Replacing existing preflight or exclusion Python clients.
- Running deployment or test suites as part of this change.

## Decisions

### D1 — Generate an OpenCode Slave-only four-file skill

Create `slave/.opencode/skills/nodestatus/` with `SKILL.md`, `SKILL.zh.md`,
`reference.md`, and `README.zh.md`, following add-tools2 conventions.

The Slave runtime loads OpenCode assets from `$remote_project/.opencode` (`remote_project` in `master.conf`).
Creating an additional `.cursor/skills` copy would introduce an undeployed,
unconsumed mirror that could drift. The add-tools2 specification is therefore
used as the generation contract rather than copied into a second runtime.

### D2 — Treat nodestatus as a direct daemon-query exception

The Slave calls `nodestatus summary|list|probe|exclude|clear` directly through
the configured Unix socket. These operations do not use `workflow_runner.py`
because they neither submit distributed jobs nor require LLM-managed polling.

The alternative—adding a workflow registry entry—would add submit/wait
semantics around a local request and conflict with the existing rule that the
runner represents partition work.

### D3 — Read runtime settings from ClusterHelm configuration

Skill commands resolve `nodestatus_bin`, `nodestatus_unix_socket`, and
`nodestatus_query_timeout` from deployed `slave.conf`. The selected partition
must exist in deployed `partitions.conf`. The generated gateway configuration
continues to derive daemon values from the same source files.

The nodestat `gateway.conf.example` remains schema documentation only. Copying
it into the skill would create a second source of truth and allow socket,
freshness, storage, and key paths to drift.

### D4 — Guard all status mutations

`exclude` and `clear` require an explicit user request, one host owned by the
selected partition, and a concrete reason. The agent performs one mutation and
one `list` verification. It never performs an implicit, broad, or repeated
mutation.

Routine job-driven exclusion remains in `node_exclude.py`, which writes through
the daemon first and maintains the legacy rollback projection. The skill does
not edit persistence files.

### D5 — Validate deployment as one coherent bundle

Before copying `.opencode`, `deploy-slave.sh` validates:

- all four nodestatus skill files;
- required OpenCode frontmatter;
- `nodestatus: allow` in the Slave agent;
- required nodestatus keys in `slave.conf`.

After copying, the script verifies the remote files and permission marker
before continuing with configuration and runtime scripts. This catches
partial transfer or stale agent policy at the deployment boundary.

The validation is implemented with existing shell tools, avoiding a new
dependency. It validates configuration presence rather than connecting to the
daemon, because runtime health belongs to deployment verification outside this
change.

## Risks / Trade-offs

- [Direct commands bypass the workflow runner's structured result] → Require
  JSON output and a `partition_report`-style summary in the skill contract.
- [Agent mutates the wrong node] → Validate partition ownership, allow one
  host, require a reason, and verify once after mutation.
- [Configuration values drift between docs and runtime] → Read runtime values
  from `slave.conf` and document the nodestat example only as a mapping.
- [Remote post-copy validation leaves an incomplete remote bundle on failure]
  → Stop before deploying configuration or scripts; rerunning deployment is
  idempotent and overwrites the bundle.
- [Strict validation blocks deployments that intentionally omit nodestatus]
  → `nodestatus_enabled` remains an explicit required key and can be set to
  `false`; the skill assets remain deployable while preflight uses fallback.

## Migration Plan

1. Add the OpenSpec artifacts and the Slave skill files.
2. Register the skill and daemon-query exception in the Slave agent policy.
3. Add local pre-copy and remote post-copy validation to `deploy-slave.sh`.
4. Deploy with the existing script when operators are ready; no new runtime
   migration command is required.
5. Roll back by removing the skill registration and validation block; existing
   preflight and nodestatus daemon integration continue unchanged.

## Open Questions

None. The skill is Slave-only, named `nodestatus`, and includes guarded
`exclude` and `clear` operations as confirmed for this change.
