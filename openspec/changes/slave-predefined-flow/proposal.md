## Why

The Slave agent currently receives a concrete task but remains free to explore, issue many shell calls, poll repeatedly, and re-plan even for known operations. This makes latency and LLM interaction count unpredictable. The Slave needs a fixed internal workflow path that still uses the LLM once to understand the request, but delegates known work to one deterministic runner call and permits free-form reasoning only when an implementation is missing or execution is exceptional.

## What Changes

- Add a Slave-local machine-readable workflow registry for known operations (`node-command`, `hostname-check`, `memory-monitor`, `fullcore-mpi`).
- Add a single-call workflow runner that performs submit, blocking wait, validation, exception classification, and report aggregation without requiring the Slave LLM to poll or inspect nodes itself.
- Fix the Slave agent decision sequence: normalize request → match workflow → invoke runner once → report. Successful workflows MUST stop without further exploration.
- Return stable exception reason codes. Only `workflow_missing`, invalid implementation, execution errors, timeouts, or report contract errors authorize bounded free-form diagnosis and at most one targeted retry.
- Keep Master submit/poll behavior and the existing job JSON / `partition_report` contract compatible. This change does not require Master-side intent routing or invert Master policy.

## Capabilities

### New Capabilities

- `slave-playbook`: Slave-local predefined workflows and a single-call deterministic runner used by the Slave LLM after task normalization.
- `exception-escalation`: Machine-classified exceptions that permit bounded Slave LLM diagnosis/recovery after the deterministic path fails or is unavailable.

### Modified Capabilities

- (none yet — no existing `openspec/specs/` baseline; behavior changes are captured via new capabilities + agent/docs updates)

## Impact

- **Slave gateway:** new `workflows/` registry and `workflow-runner.py`; reuse `run-slave.sh`, monitor, MPI, preflight, exclusions, and report generation.
- **Slave agent:** `slave-agent.md` gains a mandatory state machine, one-call happy path, forbidden exploratory behavior, and an exception interaction budget.
- **Deploy:** Slave deployment includes workflow definitions/runner and the existing deterministic monitor/MPI implementations they reference.
- **Docs / tests:** Slave-specific docs and tests cover matching, argument validation, exception classification, retry budget, and report preservation.
- **Master:** no required behavior change; existing `--prompt` and poll/report flow remains compatible.
