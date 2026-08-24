# job-wait-timeout Specification

## Purpose

Deadline-aligned Master wait timeout, remaining-seconds without inflating short deadlines, and SSH keepalive for blocking wait sessions.

## Requirements

### Requirement: Master wait timeout follows job deadline, not unused poll_timeout
`poll-wait.sh` MUST NOT use `poll_timeout` as the wait duration. The default wait timeout MUST be `default_deadline` plus `wait_slack` from `master.conf` (or an explicit `--timeout`). `submit.sh` MUST read `default_deadline` from the same config when `--deadline` is omitted.

#### Scenario: poll-wait without --timeout
- **WHEN** Master runs `poll-wait.sh --job-id <id>` with no `--timeout`
- **THEN** the timeout passed to `run-slave.sh wait` is `default_deadline + wait_slack`, not 600 and not `poll_timeout`

#### Scenario: poll.sh still uses poll_timeout
- **WHEN** Master runs a one-shot `poll.sh`
- **THEN** `poll_timeout` still bounds that SSH `poll` command only

### Requirement: Remaining deadline is not inflated
Worker remaining-time calculations MUST use remaining seconds until `deadline_at` (floored at 1 when still running) and MUST NOT apply `max(120, remaining)` in a way that lengthens a short deadline.

#### Scenario: Short remaining deadline
- **WHEN** a job has 30 seconds remaining until `deadline_at`
- **THEN** `_agent_worker` and `_worker` use 30 seconds (not 120) as the execution timeout budget

### Requirement: Blocking SSH wait stays alive
The Master SSH session for `wait` MUST set `ServerAliveInterval` (and a bounded `ServerAliveCountMax`) so a long-blocked wait is not silently dropped.

#### Scenario: Long wait SSH
- **WHEN** `poll-wait.sh` opens SSH to `run-slave.sh wait`
- **THEN** the ssh client options include `ServerAliveInterval` greater than zero
