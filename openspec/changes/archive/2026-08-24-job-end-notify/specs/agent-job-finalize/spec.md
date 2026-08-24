## ADDED Requirements

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
