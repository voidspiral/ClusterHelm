## Context

Master submits a partition job with a single SSH to the gateway, then blocks in `poll-wait.sh` → `run-slave.sh wait` until the job is terminal. Today `wait` polls `$JOB_DIR/<job_id>.json` with a 5→30s sleep backoff until `--timeout` (hardcoded 600s on Master). Agent jobs only become terminal after `timeout $timeout_sec opencode run` returns. OpenCode frequently does not self-exit, and submit `--deadline` defaults to 1800s. The waiter therefore often sits until its own timeout even after the Slave has already printed `AGENT_STATUS` and the partition-report contract.

`partition_report` remains the Master-facing contract. Master still SSHs only the gateway. This change replaces timeout-driven polling with an explicit completion signal for both normal and abnormal ends, and finalizes agent jobs as soon as the contract is observed.

## Goals / Non-Goals

**Goals:**

- Signal job end immediately on `done`, `partial`, or `failed` (including crash, OpenCode timeout rc=124, missing contract, and worker kill).
- Unblock `wait` from that signal (inotify preferred; ≤1s poll fallback).
- Finalize agent jobs from the log contract while OpenCode may still be running, then kill the CLI process group.
- Pass `--auto` on `opencode run`.
- Align wait/submit defaults with `default_deadline` + slack; do not inflate short remaining deadlines with `max(120, remaining)`.
- Keep SSH wait sessions alive with `ServerAliveInterval`.
- Preserve stdout JSON from `wait` and Master cache at `var/agent-jobs/<id>.last.json`.

**Non-Goals:**

- Changing Master routing policy or requiring Master to poll per-node.
- Defaulting to `--command` script mode.
- Changing the `partition_report` schema in a breaking way.
- SSH from Master to compute nodes.
- Replacing `poll.sh` (one-shot JSON dump still uses `poll_timeout`).

## Decisions

### D1 — Sidecar `.done` file as the completion signal

Write `$JOB_DIR/<job_id>.done` after terminal job JSON is on disk. File contents are the terminal status string (`done` / `partial` / `failed`) plus a trailing newline.

A sidecar is simpler than a FIFO: it is durable across waiter start-after-complete races, easy to test, and does not require a reader to be attached at signal time. `wait` treats an already-terminal JSON status as equivalent to a signal so older in-flight jobs without `.done` still complete.

### D2 — `wait` blocks on inotify of the job directory, not JSON backoff

Primary path: `inotifywait` on `$JOB_DIR` for create/close_write/moved_to, then re-check `.done` and JSON status. Fallback if `inotifywait` is missing: sleep 1s and re-check `.done` / terminal JSON. Do not use 5→30s progressive backoff as the primary mechanism.

`--timeout` remains a safety deadline so a lost signal cannot hang forever. On fire: dump terminal JSON if present; otherwise emit `{"error":"wait timeout","job_id":"..."}` on stderr and exit 1, as today. `wait` still prints job JSON on stdout for Master.

### D3 — Extract a Python finalizer/signal helper

Add `slave/scripts/job_complete.py` for remaining-seconds, contract parse, agent finalize, and `.done` write. `run-slave.sh` calls it from `_agent_worker`, `_worker` (after the inlined save), and a bash trap when the worker dies without a signal. Extracting the inlined agent finalizer makes the “contract while CLI still running” path unit-testable without a live OpenCode.

### D4 — Watch `.agent.log` and kill OpenCode after signaling

`_agent_worker` starts OpenCode in its own process group (setsid or equivalent), redirects to `.agent.log`, and watches the log for a complete contract. On match: finalize JSON, write `.done`, then `kill` the process group (TERM, then KILL after a short grace). If OpenCode exits first: run the same finalizer with the real rc (124 → deadline exceeded reason) and still write `.done`.

`opencode run` MUST include `--auto` so a well-behaved CLI can exit after one run; the kill path remains required because `--auto` is not guaranteed.

### D5 — Timeout alignment without a second Master poll

Master does not fetch `deadline_at` before wait (that would add a second SSH). Defaults:

- `master.conf`: `default_deadline 1800`, `wait_slack 30`. `poll_timeout` stays for `poll.sh` only; `poll-wait.sh` must not read it as the wait duration.
- `submit.sh` default `--deadline` reads `default_deadline`.
- `poll-wait.sh` default `--timeout` is `default_deadline + wait_slack`. Explicit `--timeout` still wins.
- Gateway `wait` default, if `--timeout` omitted, is remaining-until-`deadline_at` plus `wait_slack`.
- Remaining execution budget: `max(1, remaining_seconds)` — never `max(120, remaining)`.

SSH for wait: `-o ServerAliveInterval=30 -o ServerAliveCountMax=3` (values from conf if present).

### D6 — Abnormal ends always signal

| Event | Status | Signal |
|-------|--------|--------|
| Script worker success / mixed | `done` / `partial` | `.done` |
| Script worker all-fail or Python exception | `failed` | `.done` via finalize or EXIT trap |
| Complete report contract | parsed `AGENT_STATUS` | `.done` then kill CLI |
| OpenCode rc=124 | `failed` (deadline reason) unless contract already parsed | `.done` |
| Crash / missing contract | `failed` | `.done` |
| Worker killed (TERM) | best-effort `failed` + `.done` in trap | `.done` |

## Risks / Trade-offs

- **[Killing OpenCode mid-flush]** → Watch for a *complete* BEGIN/END pair before kill; after kill, re-read the log once in case a trailing write arrived.
- **[inotify not installed]** → 1s poll of `.done` is still far faster than a 30s cap; tests must cover the fallback.
- **[Waiter starts after `.done` exists]** → Existence check before blocking.
- **[Partial log match]** → Require both `AGENT_STATUS` and a full report fence; incomplete logs wait for CLI exit.
- **[Safety timeout vs hung job]** → Operators can still cap wait; the job worker may continue until its own deadline. Document that `--timeout` is waiter-side.

## Migration Plan

1. Deploy updated `run-slave.sh` + `job_complete.py` to the gateway (cn1) together; Master `poll-wait.sh` can ship in the same window.
2. Mixed versions: new wait still accepts terminal JSON without `.done`; old wait ignores `.done` and keeps polling (behavior no worse than today).
3. No job JSON schema break; extra `.done` files can be cleaned with job JSON.

## Open Questions

- None material. FIFO vs file: file chosen (D1). Optional later: include a timestamp in `.done`; not required for wait.
