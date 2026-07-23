## ADDED Requirements

### Requirement: Exception classification by workflow runner
The Slave workflow runner SHALL classify every invocation as `success` or `exception` using machine-checkable signals rather than LLM judgment. It MUST emit a stable reason code including `ok`, `workflow_missing`, `invalid_arguments`, `implementation_missing`, `execution_error`, `timeout`, or `contract_error`.

#### Scenario: All nodes succeed
- **WHEN** the worker status is `done`, or exclusion-only `partial` is allowed and there are no execution failures
- **THEN** the runner returns `outcome=success` and `reason_code=ok`

#### Scenario: Partial or failed with exec errors
- **WHEN** execution fails, times out, or returns a malformed/missing report
- **THEN** the runner returns `outcome=exception` with the corresponding reason code and available deterministic report

### Requirement: Free-form reasoning only on exception
The Slave agent MUST enter free-form diagnosis or missing-implementation work only after the runner returns `outcome=exception`. A successful workflow MUST end without additional exploration.

#### Scenario: Execution exception permits diagnosis
- **WHEN** the runner returns an execution, timeout, or contract exception
- **THEN** the already-running Slave agent diagnoses using the returned job context instead of repeating broad collection

#### Scenario: Missing workflow permits minimum implementation
- **WHEN** the runner returns `workflow_missing` or `implementation_missing`
- **THEN** the Slave agent MAY implement the smallest missing deterministic capability and attempt it once

### Requirement: Diagnosis uses returned context
Exception handling MUST use the runner's workflow id, attempt, reason code, job JSON, failure hosts, and report. The Slave agent MUST NOT repeat preflight or broad node collection already represented in that result.

#### Scenario: Diagnosis prompt contents
- **WHEN** diagnosis starts after a deterministic failure
- **THEN** the agent bases diagnosis on the structured runner result and performs only targeted inspection needed for the reason code

### Requirement: Deterministic report remains primary
On an exception, the Slave agent MUST preserve the runner's deterministic `partition_report` as the base deliverable. It MAY append diagnosis and remediation, but MUST NOT replace collected facts.

#### Scenario: LLM diagnosis succeeds
- **WHEN** the Slave agent completes diagnosis
- **THEN** `partition_report.markdown` includes the original deterministic summary plus a clearly marked diagnosis appendix

#### Scenario: LLM diagnosis fails
- **WHEN** diagnosis or retry fails
- **THEN** the final answer still includes the deterministic report and clearly records the unresolved exception

### Requirement: Bound adaptive interaction
After an exception, the Slave agent SHALL perform at most one diagnosis and one targeted retry. The runner MUST enforce the workflow attempt budget and MUST NOT retry internally.

#### Scenario: Single retry cap
- **WHEN** the retry attempt also fails or exceeds `max_attempts`
- **THEN** the Slave reports the failure and does not continue exploring or launch another workflow retry
