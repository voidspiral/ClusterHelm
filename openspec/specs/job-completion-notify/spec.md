# job-completion-notify Specification

## Purpose

Sidecar completion signal so wait unblocks on any terminal job outcome, with a safety timeout if the signal is lost.

## Requirements

### Requirement: Workers emit a completion signal on any terminal outcome
When a job reaches a terminal status (`done`, `partial`, or `failed`), the worker MUST write terminal job JSON (including `partition_report` as today) and MUST emit a sidecar completion file `$JOB_DIR/<job_id>.done` whose content is the terminal status. Script-mode `_worker` and agent-mode `_agent_worker` MUST both signal on success and on failure.

#### Scenario: Script worker succeeds
- **WHEN** `_worker` finishes with status `done` or `partial`
- **THEN** it writes terminal job JSON and creates `<job_id>.done` containing that status

#### Scenario: Script worker fails
- **WHEN** `_worker` finishes with status `failed`, or the worker process crashes before a normal finalize
- **THEN** it still writes or preserves terminal JSON when possible and creates `<job_id>.done` with `failed` (or the recorded terminal status)

#### Scenario: Agent worker times out or crashes
- **WHEN** OpenCode exits with rc=124, a non-zero crash code, or the report contract is missing
- **THEN** the job is finalized as `failed` (or the parsed status if a partial contract exists) and `<job_id>.done` is written

### Requirement: Wait blocks on the completion signal
`run-slave.sh wait` MUST unblock when the completion signal appears (or when job JSON is already terminal), then print the job JSON on stdout. Progressive 5→30s backoff MUST NOT be the primary wait mechanism. If `inotifywait` is unavailable, wait MAY poll the `.done` file at an interval of at most 1s.

#### Scenario: Signal appears before the safety timeout
- **WHEN** `<job_id>.done` is created while `wait` is blocked
- **THEN** `wait` returns the job JSON immediately without waiting for the safety timeout or a 30s backoff cap

#### Scenario: Abnormal terminal status
- **WHEN** the job becomes `failed` and the completion signal is written
- **THEN** `wait` returns that JSON immediately (not only for `done`)

#### Scenario: Already terminal without waiting
- **WHEN** job JSON is already `done`, `partial`, or `failed` at wait start (even if `.done` is missing)
- **THEN** `wait` prints the JSON and exits without sleeping the backoff sequence

### Requirement: Lost-signal safety timeout is preserved
`wait --timeout` MUST remain a safety deadline. If it fires with no completion signal and non-terminal JSON, wait MUST emit `{"error":"wait timeout","job_id":"..."}` as today. If JSON is terminal when the timer fires, wait MUST dump that JSON instead of the error object.

#### Scenario: No signal and non-terminal JSON
- **WHEN** `--timeout` elapses and the job is still non-terminal
- **THEN** wait writes the wait-timeout error JSON to stderr and exits non-zero

#### Scenario: Terminal JSON at timeout fire
- **WHEN** `--timeout` elapses but job JSON is already terminal
- **THEN** wait prints the job JSON on stdout
