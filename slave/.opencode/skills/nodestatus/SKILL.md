---
name: nodestatus
description: >-
  Inspect and manage partition-local node status through the nodestatus daemon.
  Use for node health, reachability, freshness, exclusions, partition summaries,
  targeted probes, and explicit exclude or clear requests.
compatibility: opencode
metadata:
  role: slave
  deploy: deploy-slave.sh
---

# nodestatus (Slave gateway)

This skill is deployed only to the Slave gateway by `deploy-slave.sh`, under
`.opencode/skills/nodestatus/`. Master does not load it.

`nodestatus` is a partition-local daemon query, not a distributed job. Use the
CLI directly on the gateway; do not wrap it in `workflow_runner.py`.

## When to use

- Report partition or individual-node health, freshness, reachability, or metrics.
- List excluded nodes or explain why a node is excluded.
- Refresh stale/unknown hosts with a targeted probe.
- Explicitly exclude one owned host or clear one host's exclusion.
- Provide a node-status section in `partition_report`.

## Runtime configuration

The deployed Slave configuration is authoritative. Load the binary, Unix
socket, and timeout from it before running commands:

```bash
CONF=config/slave.conf
PARTITIONS=config/partitions.conf
NODESTATUS_BIN="$(awk '$1=="nodestatus_bin"{print $2; exit}' "$CONF")"
NODESTATUS_SOCKET="$(awk '$1=="nodestatus_unix_socket"{print $2; exit}' "$CONF")"
NODESTATUS_TIMEOUT="$(awk '$1=="nodestatus_query_timeout"{print $2; exit}' "$CONF")"
: "${NODESTATUS_BIN:=/usr/local/bin/nodestatus}"
: "${NODESTATUS_SOCKET:=/run/nodestatus/nodestatus.sock}"
: "${NODESTATUS_TIMEOUT:=5}"
```

`PARTITION` must be the job/request partition and must exist in
`$PARTITIONS`. Never infer or invent a partition.

## Commands

Summary:

```bash
timeout "$NODESTATUS_TIMEOUT" "$NODESTATUS_BIN" summary \
  --partition "$PARTITION" --socket "$NODESTATUS_SOCKET" -o json
```

Full node list:

```bash
timeout "$NODESTATUS_TIMEOUT" "$NODESTATUS_BIN" list \
  --partition "$PARTITION" --socket "$NODESTATUS_SOCKET" -o json
```

Targeted refresh (only hosts owned by this partition):

```bash
timeout "$((NODESTATUS_TIMEOUT + 30))" "$NODESTATUS_BIN" probe \
  --partition "$PARTITION" --hosts "cn2,cn3" \
  --socket "$NODESTATUS_SOCKET" -o json
```

Exclude exactly one host after an explicit user request:

```bash
timeout "$NODESTATUS_TIMEOUT" "$NODESTATUS_BIN" exclude \
  --partition "$PARTITION" --host "$HOST" --reason "$REASON" \
  --socket "$NODESTATUS_SOCKET" -o json
```

Clear exactly one host after an explicit user request:

```bash
timeout "$NODESTATUS_TIMEOUT" "$NODESTATUS_BIN" clear \
  --partition "$PARTITION" --host "$HOST" --reason "$REASON" \
  --socket "$NODESTATUS_SOCKET" -o json
```

After `exclude` or `clear`, run `list` once and verify the target node's
`state` and `exclusion`; report a mismatch as failure.

## Reading output

Summary fields:

| Field | Meaning |
|-------|---------|
| `partition` / `generated_at` | Snapshot identity and timestamp |
| `total` | Nodes in the configured nodeset |
| `states` | Counts for online, offline, degraded, excluded, unknown |
| `fresh` / `stale` | Nodes inside/outside the freshness window |
| `sources` | Counts by heartbeat/probe source |

Node fields:

| Field | Meaning |
|-------|---------|
| `state` | Effective state; active exclusion overrides health |
| `health_state` | Health before exclusion policy is applied |
| `fresh` / `last_seen` | Whether evidence is current and when it arrived |
| `source` / `diagnostic` | Evidence source and failure detail |
| `metrics` | CPU, load, memory, swap, disk, I/O, uptime, cores |
| `exclusion` | Active flag, reason, timestamps, success/failure counts |

Treat a node as immediately runnable only when `fresh=true`,
`state=online`, and `exclusion.excluded` is not true. A stale online result
requires a targeted `probe` or normal preflight before execution.

## Reporting to user

```markdown
# Node status: test (cn[1-3])
- Snapshot: 2026-07-28T11:00:00Z
- States: online 2, excluded 1
- Fresh: 2/3
- Excluded: cn3 — repeated preflight failure

## Per-node
- **cn1** online, fresh, load1=0.42, mem_avail_mb=8192
- **cn2** online, fresh, load1=0.31, mem_avail_mb=7800
- **cn3** excluded, health=offline — repeated preflight failure
```

Include stale/unknown nodes and diagnostics. Do not hide excluded nodes from
the partition total.

## Job flow

1. Read the partition from job/request context and confirm it in
   `config/partitions.conf`.
2. Load runtime values from `slave.conf`.
3. Use `summary` for aggregate questions and `list` for node-level questions.
4. Use `probe` only when current evidence is stale/unknown or explicitly requested.
5. For `exclude`/`clear`, confirm the host belongs to the selected partition,
   require an explicit request and reason, mutate one host, then verify once.
6. Return one consolidated `partition_report`-style result.

If the daemon query fails, report that nodestatus is unavailable. Normal job
preflight already falls back to ping/SSH and the legacy exclusion projection;
do not recreate that fallback with an ad-hoc SSH loop.

## Forbidden

- Querying or mutating a partition not owned by this Slave.
- Broad or automatic `exclude`/`clear`; each mutation must target one host.
- Mutating without an explicit user request and a concrete reason.
- Treating stale status as proof that a node is runnable.
- Hand-written ping/SSH loops when nodestatus or normal preflight is available.
- Editing `node-status*.json` or `node-exclusions.json` directly.
- Calling remote HTTP status endpoints; use the local Unix socket.

## Reference

Field definitions, configuration mapping, and examples: [reference.md](reference.md)

中文说明：[SKILL.zh.md](SKILL.zh.md) · [README.zh.md](README.zh.md)

## Master workspace (no this skill)

Master delegates the request to the partition Slave:

```bash
./master/scripts/submit.sh --partition test --prompt \
  'Load nodestatus; summarize current node health and exclusions; return a partition report' \
  --task nodestatus
```
