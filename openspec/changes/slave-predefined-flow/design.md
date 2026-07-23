## Context

The Slave is itself an LLM agent. On an agent-mode job it receives a concrete task after gateway preflight, but its current instructions still allow it to inspect files, issue node commands, create nested jobs, poll repeatedly, and decide how to assemble the report. Known tasks therefore consume an unpredictable number of model/tool interactions.

The gateway already has deterministic building blocks: `run-slave.sh` owns preflight, exclusions, per-node execution, blocking wait, and `partition_report`; `mem-api.sh` implements memory collection; and `run-fullcore-test.sh` implements MPI testing. The missing layer is a Slave-local workflow contract that lets the LLM select one known operation and invoke it once.

Constraints:

- The Slave LLM remains the task interpreter; this change does not move intent routing to Master.
- Existing Master `--prompt` submission and polling remain compatible.
- The normal path must not require per-node LLM tool calls or LLM-managed polling.
- Existing deterministic scripts remain the source of execution truth.

## Goals / Non-Goals

**Goals:**

- Fix the Slave sequence to `normalize → match → deterministic run → validate → report`.
- Complete a known successful task with one aggregated runner tool call after task interpretation.
- Allow free-form reasoning only for missing workflow implementations or classified exceptions.
- Bound exception handling to one diagnosis and at most one targeted retry.
- Preserve a code-generated `partition_report` even when diagnosis fails.

**Non-Goals:**

- Removing the Slave LLM from agent-mode jobs.
- Changing Master routing/default policy.
- Implementing a generic DAG/workflow platform.
- Unbounded autonomous remediation or silent exclusion changes.

## Decisions

### D1 — Slave-local JSON workflow registry

Add `slave/workflows/*.json`. Each definition declares an id, aliases/hints for LLM matching, typed arguments, a deterministic implementation, success policy, and safe retry policy. JSON avoids a new YAML dependency.

Initial workflows:

| id | implementation |
|----|----------------|
| `node-command` | caller-supplied per-node command through `run-slave.sh` |
| `hostname-check` | fixed per-node `hostname -s` |
| `memory-monitor` | existing partition memory collector |
| `fullcore-mpi` | existing gateway MPI test |

### D2 — One aggregated runner call

Add `slave/scripts/workflows/workflow-runner.py` with `list`, `describe`, and `run` commands. `run` accepts `workflow_id`, partition, and typed arguments. It validates inputs, resolves the deterministic command, submits it through `run-slave.sh`, uses the existing blocking `wait`, validates terminal JSON, classifies the outcome, and prints one JSON object.

The runner never invokes OpenCode. It returns:

```json
{
  "workflow_id": "hostname-check",
  "outcome": "success",
  "reason_code": "ok",
  "attempt": 1,
  "retry_allowed": false,
  "job": {},
  "partition_report": {}
}
```

This makes one Slave tool call represent preflight, execution, waiting, and report aggregation.

### D3 — Code-owned classification

The runner, not the LLM, maps results to stable reason codes:

- `ok`
- `workflow_missing`
- `invalid_arguments`
- `implementation_missing`
- `execution_error`
- `timeout`
- `contract_error`

`done` is success. `partial` is success only when there are no execution failures and the workflow permits exclusion-only partial results. Other terminal results are exceptions.

### D4 — Mandatory Slave agent state machine

`slave-agent.md` requires:

1. Normalize the task to exactly one workflow id and arguments, without exploratory commands.
2. Invoke `workflow-runner.py run` exactly once.
3. On `outcome=success`, return the runner's report immediately.
4. On an exception reason code, diagnose from the returned job JSON/log pointers; do not repeat preflight or broad collection.
5. Perform at most one targeted retry when `retry_allowed=true`.
6. Report after the retry; do not continue exploring.

Unknown work enters the missing-implementation path. The agent may implement the minimum missing capability, execute it once, and recommend promoting it into the registry.

### D5 — Retry budget encoded in data and policy

The runner accepts `--attempt` (default 1) and reports `retry_allowed`. An attempt greater than the workflow's `max_attempts` is rejected. Initial workflows use `max_attempts: 2`, allowing one targeted retry. Stateful actions such as clearing exclusions are not automatic retry steps.

The agent policy reinforces the budget; code prevents runner-level retry loops.

### D6 — Deterministic report remains primary

The runner returns the exact worker `partition_report`. On an exception, the agent may append `Diagnosis` and `Remediation`, but it must preserve deterministic facts. A diagnosis failure cannot erase the base report.

## Risks / Trade-offs

- [LLM chooses the wrong workflow] → Require exact id selection from a short catalog and validate all typed arguments.
- [Agent ignores the one-call rule] → Put the state machine and forbidden actions before general responsibilities; test the command contract independently.
- [Registry drifts from deployed scripts] → Validate implementation paths and deploy registry, runner, monitor, and MPI scripts together.
- [A partial result is misclassified] → Keep classification explicit per workflow and cover exclusion-only versus execution-failure cases in tests.
- [A retry causes side effects] → One retry maximum; no automatic exclusion clearing; report every attempted action.

## Migration Plan

1. Add tests for loading/matching, arguments, classification, retry budget, and report preservation.
2. Add registry and runner without changing `run-slave.sh` or Master interfaces.
3. Deploy workflow assets and deterministic implementations to the gateway.
4. Update Slave agent rules and Slave documentation.
5. Keep the old free-form path available only after runner exceptions; rollback by removing the mandatory workflow section.
