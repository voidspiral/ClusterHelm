## ADDED Requirements

### Requirement: Status intents load the Slave skill
The generated Slave prompt and deployed agent policy SHALL require loading the
`nodestatus` skill and directly querying the local Unix socket for requests
about node health, status, freshness, reachability, probe, or exclusions.

#### Scenario: User asks for partition node status
- **WHEN** Master delegates a partition node-status request
- **THEN** the Slave loads `nodestatus`, runs the appropriate status command,
  and returns a node-status partition report

### Requirement: Ordinary jobs reuse deterministic status evidence
For requests not primarily about node status, the Slave SHALL consume the
nodestatus-first evidence already persisted by preflight and SHALL NOT repeat
the status query merely to demonstrate skill invocation.

#### Scenario: User asks for a hostname check
- **WHEN** preflight has completed and the task maps to `hostname-check`
- **THEN** the Slave runs the workflow once and reports the preflight
  nodestatus provenance with the workflow result

### Requirement: Master delegates status requests
Master SHALL NOT load the Slave-only nodestatus skill locally. It SHALL route
status requests to the owning Slave with an explicit instruction to load the
skill and SHALL present the returned partition report.

#### Scenario: Master receives status request
- **WHEN** a user asks Master for the health of the test partition
- **THEN** Master submits one agent-mode job to the test Slave with a
  nodestatus-specific prompt and waits once for the report
