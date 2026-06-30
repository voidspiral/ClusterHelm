# Memory monitor — JSON reference

## `memmon.py` output (one line per node)

```json
{
  "host": "cn1",
  "mem_total_mb": 3350,
  "mem_used_mb": 719,
  "mem_avail_mb": 2631,
  "mem_used_pct": 21.5,
  "swap_total_mb": 0,
  "swap_used_mb": 0
}
```

| Field | Type | Source |
|-------|------|--------|
| `host` | string | Short hostname |
| `mem_total_mb` | int | `MemTotal` from `/proc/meminfo` |
| `mem_avail_mb` | int | `MemAvailable` |
| `mem_used_mb` | int | `mem_total_mb − mem_avail_mb` (rounded) |
| `mem_used_pct` | float | `mem_used / total × 100`, one decimal |
| `swap_total_mb` | int | `SwapTotal` |
| `swap_used_mb` | int | `SwapTotal − SwapFree` |

Values are rounded to whole MB except `mem_used_pct`.

## `mem-api.sh partition` aggregate

```json
{
  "partition": "test",
  "partition_nodeset": "cn[1-10]",
  "job_id": "job-20260630T120000Z-12345",
  "status": "partial",
  "reachable": ["cn1", "cn2"],
  "excluded": ["cn5"],
  "unreachable": ["cn9"],
  "nodes": [
    {"host": "cn1", "mem_total_mb": 3350, "mem_used_mb": 719, "mem_avail_mb": 2631, "mem_used_pct": 21.5, "swap_total_mb": 0, "swap_used_mb": 0}
  ],
  "parse_errors": ["cn3: invalid JSON"]
}
```

`parse_errors` is omitted when all exec-ok nodes returned valid JSON.

## Paths

| Artifact | Path |
|----------|------|
| Collector | `/home/code/agents/scripts/monitor/memmon.py` |
| CLI | `/home/code/agents/scripts/monitor/mem-api.sh` |
| Job runner | `/home/code/agents/scripts/jobs/run-slave.sh` |

## Partition remote command (simulation)

`memmon.py` on disk: gateway only (`deploy-monitor.sh`). Partition jobs use:

```bash
python3 /home/code/agents/scripts/monitor/memmon.py --remote-cmd
```

Output is a one-liner (`echo <base64> | base64 -d | python3`) that runs the same collector on cn2–cn10 without a deployed file. Future releases will use a per-node API or uniform install instead.
