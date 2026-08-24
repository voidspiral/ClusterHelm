## Why

`run-slave.sh wait` polls job JSON with a 5→30s backoff until `--timeout` (default 600s), while agent jobs stay non-terminal until `timeout $timeout_sec opencode run` exits. OpenCode often does not self-exit, so every agent job appears to wait until the timeout rather than completing when the report contract is ready. Operators need a direct job-end notification for both normal (`done`/`partial`) and abnormal (`failed`/crash/timeout/kill) outcomes.

## What Changes

- Emit a sidecar completion signal next to job JSON when a worker reaches any terminal outcome.
- Change `wait` to block on that signal (inotify, with a short poll fallback) instead of progressive JSON backoff.
- Finalize agent jobs as soon as the report contract appears in `.agent.log`, write the signal, then kill the OpenCode process group so waiters are not held by a hung CLI.
- Signal on OpenCode timeout (rc=124), crash, missing contract, worker kill, and script-mode `_worker` success or failure.
- Pass `--auto` on `opencode run` so the CLI can exit after one run.
- Align Master wait timeout with job deadline (+ slack); stop using unused `poll_timeout` in `poll-wait.sh`; keep `--timeout` as a lost-signal safety net.
- Keep SSH wait sessions alive with `ServerAliveInterval`.
- Update architecture docs so wait is described as signal-blocked, not a poll loop.

## Capabilities

### New Capabilities

- `job-completion-notify`: Sidecar completion signal, wait unblocking on normal and abnormal terminal status, and safety timeout if the signal is lost.
- `agent-job-finalize`: Early finalize from the report contract while OpenCode is still running, `--auto` invocation, and process-group kill after signaling.
- `job-wait-timeout`: Deadline-aligned wait timeout, remaining-seconds without inflating short deadlines, and SSH keepalive for blocking wait.

### Modified Capabilities

- (none; the repository has no matching baseline capability under `openspec/specs/`)

## Impact

- **Slave runtime:** `slave/scripts/run-slave.sh` (`wait`, `_agent_worker`, `_worker`, `submit`); new helper `slave/scripts/job_complete.py`.
- **Master runtime:** `master/scripts/poll-wait.sh`, `master/scripts/submit.sh`, `master/config/master.conf`.
- **Agent CLI:** OpenCode `run --auto` from `_agent_worker`; `scripts/deploy/test-agent-chain.sh` already uses `--auto`.
- **Docs:** `docs/architecture.md`, `docs/zh/architecture.md`; optional Slave agent note that the worker finalizes on the printed contract.
- **Tests:** new unittest coverage under `tests/` (TDD).
- **Non-impact:** Master still SSHs only the gateway with one blocking `poll-wait.sh`; `partition_report` JSON contract stays compatible; agent-to-agent `--prompt` remains the default.
