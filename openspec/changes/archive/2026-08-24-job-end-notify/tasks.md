## 1. Tests first (TDD)

- [x] 1.1 Add unittest coverage that `wait` returns as soon as `<job_id>.done` appears (or JSON is already terminal), not after backoff/timeout
- [x] 1.2 Add coverage that `wait` returns on `failed` / abnormal terminal status, not only `done`
- [x] 1.3 Add coverage that the agent finalizer writes JSON + `.done` when the report contract appears in the log while a fake OpenCode process is still running, then that process is killed
- [x] 1.4 Add coverage that `wait --timeout` still errors when no signal and JSON stays non-terminal
- [x] 1.5 Add coverage that `poll-wait.sh` default timeout is `default_deadline + wait_slack`, does not use `poll_timeout`, and SSH wait includes `ServerAliveInterval`
- [x] 1.6 Add coverage that the OpenCode invocation includes `--auto` and remaining-seconds is not inflated with `max(120, remaining)`

## 2. Completion helper and wait

- [x] 2.1 Add `slave/scripts/job_complete.py` for remaining seconds, contract parse, agent finalize, and `.done` write
- [x] 2.2 Change `cmd_wait` to block on inotify of `.done` (1s poll fallback) and keep `--timeout` as a safety net
- [x] 2.3 Write `.done` from `_worker` on success and failure; trap crashes/kills so abnormal ends still signal

## 3. Agent early finalize

- [x] 3.1 Watch `.agent.log` for a complete report contract; finalize and signal immediately
- [x] 3.2 Kill the OpenCode process group after signaling; still finalize + signal if the CLI exits first
- [x] 3.3 Invoke OpenCode with `run --agent … --auto`

## 4. Timeout alignment

- [x] 4.1 Add `default_deadline` and `wait_slack` to `master.conf`; stop reading `poll_timeout` in `poll-wait.sh` (keep it for `poll.sh`)
- [x] 4.2 Default `submit.sh --deadline` and `poll-wait.sh --timeout` from those knobs; pass remaining-aligned timeout to wait
- [x] 4.3 Replace `max(120, remaining)` with non-inflating remaining seconds in `_agent_worker` and `_worker`
- [x] 4.4 Set `ServerAliveInterval` / `ServerAliveCountMax` on the wait SSH session

## 5. Docs and validation

- [x] 5.1 Update `docs/architecture.md` and `docs/zh/architecture.md` so wait is signal-blocked, not a poll loop
- [x] 5.2 Note in `slave-agent.md` that printing the report contract allows the worker to finalize and stop the CLI
- [x] 5.3 Run the new tests and `openspec validate job-end-notify`
