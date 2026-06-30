---
name: memory-monitor
description: >-
  Monitor partition node memory via mem-api.sh on the Slave gateway. Use when
  the user asks about RAM, memory usage, OOM risk, or partition memory health.
  Deployed to Slave only — not used on Master workspace.
---

# Memory Monitor (Slave gateway)

This skill is **deployed to the Slave gateway** (e.g. cn1) via **`deploy-slave.sh`** (skills under `deploy/slave-agent/.cursor/skills/`). Monitor CLI binaries are deployed separately via **`scripts/monitor/deploy-monitor.sh`**. It does **not** apply on the Master workspace.

Run on the **gateway** using `mem-api.sh`; it reuses `run-slave.sh` preflight, exclusion, and job JSON — do not SSH nodes manually for `free`/`meminfo`.

## Deployment (simulation phase)

| Location | `memmon.py` on disk? | Partition collect |
|----------|----------------------|-------------------|
| cn1 gateway | Yes (`deploy-monitor.sh`) | `local` uses file; `partition` uses `--remote-cmd` |
| cn2–cn10 | **No** (not deployed yet) | Inline via `memmon.py --remote-cmd` in job `--command` |

`mem-api.sh partition` already uses `--remote-cmd` so reachable cn2–cn10 do not need the file. **Future:** per-node monitoring API / uniform install on all nodes; then `--command` can use the installed path everywhere.

See `scripts/monitor/README.md`.

## When to use

- User asks about memory, RAM, swap, OOM risk, or partition memory health
- Before heavy MPI or batch jobs to check headroom
- Routine partition memory patrol

## Commands

### Local (this host only)

```bash
/home/code/agents/scripts/monitor/mem-api.sh local
```

Returns one JSON object for the current node (gateway cn1 counts as a compute node).

### Partition-wide

```bash
/home/code/agents/scripts/monitor/mem-api.sh partition test
```

Subset of nodes:

```bash
/home/code/agents/scripts/monitor/mem-api.sh partition test --subset cn[1-3]
```

Internally: `run-slave.sh submit` with `$(python3 memmon.py --remote-cmd)` on each reachable, non-excluded node (inline — no file required on cn2–cn10), polls until terminal, aggregates JSON.

## Reading output

### Single node (`local`)

| Field | Meaning |
|-------|---------|
| `mem_total_mb` | Total RAM |
| `mem_used_mb` | Used (total − available) |
| `mem_avail_mb` | Available for new workloads |
| `mem_used_pct` | Used percentage |
| `swap_total_mb` / `swap_used_mb` | Swap capacity and use |

### Partition aggregate

Top-level fields:

- `partition`, `job_id`, `status` — job metadata
- `reachable`, `excluded`, `unreachable` — preflight / exclusion (same as job JSON)
- `nodes` — array of per-node memmon JSON objects
- `parse_errors` — present if any stdout was not valid JSON

### Alert thresholds (report only — no auto-exclude in MVP)

| `mem_used_pct` | Suggestion |
|----------------|------------|
| &lt; 85% | OK |
| 85–95% | Warn — high pressure |
| &gt; 95% | Critical — OOM risk |

High swap use with low avail_mb also warrants a warning.

## Reporting to user

After `partition`, synthesize a summary in `partition_report` style:

```markdown
# Memory report: test
- Job: memory-monitor (`job-...`)
- Status: done
- Reachable: 8/10 — cn1, cn2, …
- Excluded: cn5
- Unreachable: cn9

| Host | Used % | Avail MB | Swap used MB |
|------|--------|----------|--------------|
| cn1  | 21.5   | 2631     | 0            |
| cn2  | 78.2   | 512      | 128          |

**Warnings:** cn2 mem_used_pct 78% (elevated)
```

Include excluded/unreachable nodes in prose — they were not sampled.

## Job flow

`mem-api.sh partition` already handles submit + poll. You do **not** need a separate `poll` unless debugging a specific `job_id`.

Direct low-level equivalent (debug only):

```bash
/home/code/agents/scripts/jobs/run-slave.sh submit \
  --partition test \
  --command "$(python3 /home/code/agents/scripts/monitor/memmon.py --remote-cmd)" \
  --task memory-monitor
/home/code/agents/scripts/jobs/run-slave.sh poll --job-id <job_id>
```

## Forbidden

- SSH loop over partition nodes running `free` or ad-hoc awk — use `mem-api.sh partition`
- Skipping preflight / exclusion when sampling the partition
- Nodes outside the owned partition subset

## Reference

Field definitions and examples: [reference.md](reference.md)

中文说明：[README.zh.md](README.zh.md)
