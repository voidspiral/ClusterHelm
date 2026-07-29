## Context

`job_preflight.py` already calls `query_partition()` and probes stale hosts
before ping/SSH. However, the client returns `(None, None)` for every failure,
discarding whether nodestatus was disabled, missing, timed out, returned an
error, or emitted invalid JSON. When stale evidence falls back, per-node
nodestatus fields are also discarded and the final job only says `legacy`.

The dynamically generated agent prompt is more specific than the deployed
agent document and still says availability is `ping → SSH`. It lists only
workflow-runner operations and does not explain the nodestatus direct-query
exception. This prompt conflict explains why the Slave did not load the skill
for a node-status request and interpreted legacy fields as the whole process.

## Goals / Non-Goals

**Goals:**

- Make deterministic preflight visibly nodestatus-first.
- Preserve both nodestatus evidence and the exact fallback reason.
- Require the Slave to load the skill for explicit node-status intents.
- Teach Master to delegate those intents with an unambiguous prompt.
- Retain reliable ping/SSH fallback.

**Non-Goals:**

- Requiring the LLM to load the skill for every unrelated partition task.
- Removing ping/SSH fallback.
- Changing the nodestatus Go API or daemon.
- Making Master query compute nodes directly.

## Decisions

### D1 — Separate execution from instruction

Ordinary partition jobs SHALL use nodestatus through deterministic preflight,
not through an LLM skill call. The skill SHALL be loaded when the user's task
is itself about status, freshness, health, probe, or exclusion.

This uses the tool for every job without spending additional model/tool calls,
while preserving the richer skill behavior for interactive status requests.

### D2 — Return structured attempt metadata

The Python client SHALL return classified attempt metadata from query and
probe operations. Existing two-value APIs remain compatible; new detailed
functions expose `available`, `result`, and a bounded error string.

Classifications include `ok`, `disabled`, `command_failed`, `timeout`,
`invalid_json`, and `unavailable`.

### D3 — Preserve per-node evidence

Each job node SHALL retain a `nodestatus` object when the daemon returned that
host, even if the result was stale and ping/SSH became authoritative for
availability. `status_source` identifies the final decision source, while
`status_fallback_reason` explains why fallback occurred.

Top-level `nodestatus_snapshot` SHALL always record whether a query was
attempted and its outcome.

### D4 — Eliminate prompt-policy conflict

The generated `_agent_worker` prompt SHALL state:

1. preflight has already queried nodestatus and probed stale hosts;
2. the agent must inspect `nodestatus_snapshot` and per-node provenance;
3. node-status intents load the `nodestatus` skill and directly query the Unix
   socket;
4. other known tasks use the workflow runner and reuse preflight evidence.

Master SHALL deny local loading of the Slave-only skill and delegate with a
prompt that explicitly asks the Slave to load it.

## Risks / Trade-offs

- [More job JSON data] → Store only the existing bounded node payload and
  bounded diagnostic strings.
- [Fallback is mistaken for nodestatus not being used] → Preserve attempt,
  evidence, and reason separately from final decision source.
- [Agent redundantly queries status for unrelated work] → Limit direct skill
  invocation to explicit status intents.
- [Client API breakage] → Keep existing query/probe wrappers and add detailed
  variants.

## Migration Plan

1. Add failing tests for provenance, evidence, and prompt routing.
2. Implement detailed client results and preflight persistence.
3. Align generated and deployed agent instructions.
4. Deploy Slave assets to cn1 and verify through a status-intent job.

## Open Questions

None.
