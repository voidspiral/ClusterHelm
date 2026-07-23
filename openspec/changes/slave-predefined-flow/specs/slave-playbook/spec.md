## ADDED Requirements

### Requirement: Slave-local workflow registry
The Slave gateway SHALL provide a machine-readable registry of named workflows. Each workflow MUST declare an id, task matching hints, typed arguments, deterministic implementation, success policy, and retry budget.

#### Scenario: List known playbooks
- **WHEN** the Slave agent or operator requests the workflow catalog
- **THEN** the system returns `node-command`, `hostname-check`, `memory-monitor`, and `fullcore-mpi`

#### Scenario: Unknown workflow is classified
- **WHEN** the Slave agent requests an id that is not in the registry
- **THEN** the runner returns `outcome=exception` and `reason_code=workflow_missing` without launching a worker

### Requirement: Single-call deterministic workflow execution
For a known workflow, the Slave agent SHALL invoke one aggregated runner command. The runner MUST validate arguments, submit deterministic execution, block until terminal, validate the report, and return one structured JSON result without invoking an LLM.

#### Scenario: Hostname-check happy path
- **WHEN** the Slave agent runs workflow `hostname-check` for partition `test` and all non-excluded nodes succeed
- **THEN** one runner call returns `outcome=success`, `reason_code=ok`, and the worker `partition_report`

#### Scenario: Memory-monitor happy path
- **WHEN** the Slave agent runs workflow `memory-monitor`
- **THEN** the runner uses the existing deterministic memory collector and returns its consolidated partition result without LLM-managed polling

#### Scenario: Fullcore-mpi happy path
- **WHEN** the Slave agent runs workflow `fullcore-mpi` with valid duration and interval
- **THEN** the runner invokes the registered MPI implementation with validated arguments and returns a consolidated result

### Requirement: Slave agent follows fixed workflow state machine
The Slave agent MUST normalize a received task to one workflow id and typed arguments before executing tools. If the workflow succeeds, it MUST report immediately without exploratory commands, per-node operations, or additional polling.

#### Scenario: Known request uses the runner
- **WHEN** the Slave receives a task that matches `hostname-check`
- **THEN** it invokes the workflow runner once and does not run node SSH or poll commands itself

#### Scenario: Successful result stops interaction
- **WHEN** the runner returns `outcome=success`
- **THEN** the Slave produces the final report without further environment inspection or remediation

### Requirement: Same report contract as script mode
Workflow execution MUST preserve the same job JSON terminal fields and `partition_report` shape used by script-mode `_worker`, so the current Master polling and reporting contract remains unchanged.

#### Scenario: Runner returns worker report
- **WHEN** a workflow job reaches `done|partial|failed`
- **THEN** the runner returns the worker's `partition_report` without asking the Slave LLM to rebuild node facts
