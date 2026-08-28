# agent-job-finalize Specification

## Purpose

Early agent-job finalize from the report contract while OpenCode is still running, `--auto` invocation, and process-group kill after signaling.

## Requirements

### Requirement: Agent worker finalizes on the report contract
`_agent_worker` MUST watch `.agent.log` for a complete report contract (`AGENT_STATUS` plus `PARTITION_REPORT_BEGIN`/`END`). On a complete contract it MUST finalize job JSON immediately, write the completion signal, then kill the OpenCode process group so waiters are not held by a hung CLI.

#### Scenario: Contract appears while OpenCode is still running
- **WHEN** `.agent.log` contains a complete report contract and the OpenCode process is still alive
- **THEN** the job is finalized and signaled, and the OpenCode process group is terminated without waiting for the CLI to self-exit

### Requirement: OpenCode exit still finalizes
If OpenCode exits first (any exit code), `_agent_worker` MUST run the existing finalizer path and MUST still write the completion signal.

#### Scenario: CLI exits before a log watcher fires
- **WHEN** `opencode run` returns any rc and the job is not yet terminal
- **THEN** the finalizer parses the log or records a missing-contract failure, writes terminal JSON, and writes `<job_id>.done`

### Requirement: OpenCode is invoked with --auto
The agent-mode OpenCode invocation MUST include `--auto` so the CLI can exit after one run, matching `scripts/deploy/test-agent-chain.sh`.

#### Scenario: Agent runtime is opencode
- **WHEN** `_agent_worker` launches the configured OpenCode binary
- **THEN** the command includes `run --agent <agent> --auto` and the task prompt

### Requirement: Incident sidecar is Master-visible while the agent is running
On wrap or workflow-runner failure, a sidecar `<job_id>.incident.json` MUST be written (via `CLUSTERHELM_INCIDENT_PATH`). `supervise` MUST merge it into running job JSON (`summary`, `failures[]`, `agent_progress`, `updated_at`) without writing `.done` or killing OpenCode.

#### Scenario: Wrap exits non-zero before the report contract
- **WHEN** `mpi-monitor wrap` returns a non-zero exit and `CLUSTERHELM_INCIDENT_PATH` is set
- **THEN** the sidecar exists and a subsequent poll of job JSON includes `summary` and a `failures[]` entry with step, hosts, and exit code while `status` remains `running`

### Requirement: Incident budget finalizes a hung diagnosis
After the first incident sidecar appears, if no complete report contract is printed within the incident budget (default 120s, `CLUSTERHELM_INCIDENT_BUDGET_SEC`), `supervise` MUST finalize the job as `failed` using the incident record plus agent-log tail, write `.done`, and terminate the OpenCode process group.

#### Scenario: Agent loops after wrap failure
- **WHEN** an incident sidecar exists and the budget elapses with no `AGENT_STATUS` + `PARTITION_REPORT_*` contract
- **THEN** the job is `failed`, `partition_report.markdown` includes the incident and log tail, and waiters are released
