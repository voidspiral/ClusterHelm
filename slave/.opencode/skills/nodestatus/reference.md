# nodestatus — JSON and configuration reference

## CLI contract

All interactive Slave commands use the gateway-local Unix socket:

```text
/usr/local/bin/nodestatus <command> \
  --partition <logical-partition> \
  --socket /run/nodestatus/nodestatus.sock -o json
```

Runtime values must be read from
`/home/smt/agents/config/slave.conf`; the paths above are defaults, not a
second configuration source.

## Summary output

```json
{
  "schema_version": 1,
  "partition": "test",
  "generated_at": "2026-07-28T11:00:00Z",
  "total": 3,
  "states": {
    "online": 2,
    "excluded": 1
  },
  "fresh": 2,
  "stale": 1,
  "sources": {
    "heartbeat": 2,
    "probe": 1
  }
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `schema_version` | integer | Contract version; currently `1` |
| `partition` | string | Logical partition requested |
| `generated_at` | RFC3339 string | Gateway snapshot time |
| `total` | integer | Nodes in the configured nodeset |
| `states` | object | Effective-state counts |
| `fresh` / `stale` | integer | Evidence inside/outside freshness window |
| `sources` | object | Counts by last evidence source |

## List and probe output

`list` and `probe` return the same list envelope. Probe first refreshes only
the requested hosts.

```json
{
  "schema_version": 1,
  "partition": "test",
  "generated_at": "2026-07-28T11:00:00Z",
  "nodes": [
    {
      "host": "cn1",
      "state": "online",
      "health_state": "online",
      "last_seen": "2026-07-28T10:59:52Z",
      "fresh": true,
      "source": "heartbeat",
      "metrics": {
        "cpu_pct": 7.2,
        "load1": 0.42,
        "load5": 0.38,
        "load15": 0.31,
        "mem_total_mb": 16384,
        "mem_avail_mb": 8192,
        "swap_total_mb": 2048,
        "swap_free_mb": 2048,
        "disk_total_mb": 102400,
        "disk_free_mb": 64000,
        "uptime_seconds": 86400,
        "cores": 16
      },
      "agent_version": "0.1.0"
    },
    {
      "host": "cn3",
      "state": "excluded",
      "health_state": "offline",
      "fresh": false,
      "source": "probe",
      "diagnostic": "ssh failed",
      "exclusion": {
        "excluded": true,
        "reason": "repeated preflight failure",
        "excluded_at": "2026-07-28T10:30:00Z",
        "fail_count": 3
      }
    }
  ]
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `nodes[].host` | string | Short hostname |
| `nodes[].state` | enum | `online`, `offline`, `degraded`, `excluded`, `unknown` |
| `nodes[].health_state` | enum | Health before exclusion override |
| `nodes[].fresh` | boolean | Last evidence is within configured freshness |
| `nodes[].last_seen` | RFC3339 string | Last accepted heartbeat/probe |
| `nodes[].source` | string | Evidence source |
| `nodes[].diagnostic` | string | Probe/health diagnostic |
| `nodes[].metrics` | object | Optional resource metrics |
| `nodes[].exclusion` | object | Optional exclusion policy state |

An active `exclusion.excluded=true` forces effective `state=excluded` while
preserving `health_state`.

## Mutation output

Successful exclusion:

```json
{"excluded": true, "host": "cn3"}
```

Successful clear:

```json
{"cleared": true, "host": "cn3"}
```

These acknowledgements are not sufficient verification. Run `list` once and
check the node's effective `state` and `exclusion` fields.

## Configuration ownership and mapping

ClusterHelm owns deployment-time values. The nodestat example file documents
the daemon schema but is not deployed as an independent source of truth.

| nodestat gateway key | ClusterHelm source / generated value |
|----------------------|---------------------------------------|
| `partition` | `master/config/slaves.conf`, checked against `partitions.conf` |
| `nodeset` | `master/config/slaves.conf`; `partitions.conf` remains logical mapping SoT |
| `listen` | `slave.conf:nodestatus_listen` |
| `socket_path` | `slave.conf:nodestatus_unix_socket` |
| `store_path` | `/home/smt/agents/var/agent-jobs/node-status.json` |
| `exclusion_store_path` | `/home/smt/agents/var/agent-jobs/node-status-exclusions.json` |
| `legacy_exclusion_path` | `/home/smt/agents/var/agent-jobs/node-exclusions.json` |
| `freshness` | `slave.conf:nodestatus_freshness` |
| `heartbeat_timeout` | `slave.conf:nodestatus_heartbeat_timeout` |
| `auth_key_file` | `/etc/nodestatus/partition.key`, supplied from deployment input |
| `key_id` | `current` |
| `auto_recover` | generated as `true` |
| `auto_recover_threshold` | generated as `3` |

Slave interactive runtime keys:

| Key | Default | Consumer |
|-----|---------|----------|
| `nodestatus_enabled` | `true` | preflight/fallback selection |
| `nodestatus_bin` | `/usr/local/bin/nodestatus` | skill and Python client |
| `nodestatus_gateway_config` | `/etc/nodestatus/gateway.conf` | gateway service deployment |
| `nodestatus_query_timeout` | `5` | skill and Python client |
| `nodestatus_unix_socket` | `/run/nodestatus/nodestatus.sock` | skill and Python client |

## State interpretation

| Condition | Interpretation |
|-----------|----------------|
| `fresh=true`, `state=online`, not excluded | Current evidence permits normal preflight optimization |
| `state=degraded` | Reachable but health signal is degraded; report metrics/diagnostic |
| `state=offline` | Current health says unavailable |
| `state=excluded` | Policy blocks execution regardless of `health_state` |
| `state=unknown` or `fresh=false` | Evidence is insufficient; use targeted probe or normal preflight |

## Fallback boundary

- `nodestatus_client.py` returns no status on timeout, malformed JSON, disabled
  configuration, missing binary, or daemon/socket failure.
- Normal preflight then performs its existing ping/SSH checks.
- `node_exclude.py` uses the daemon first and maintains
  `node-exclusions.json` as a rollback projection.
- The interactive skill reports daemon failure; it does not implement another
  SSH loop or write either exclusion store directly.

## Relevant paths

| Artifact | Project path | Deployed path |
|----------|--------------|---------------|
| Skill | `slave/.opencode/skills/nodestatus/` | `/home/smt/agents/.opencode/skills/nodestatus/` |
| Slave config | `slave/config/slave.conf` | `/home/smt/agents/config/slave.conf` |
| Partition SoT | `master/config/partitions.conf` | `/home/smt/agents/config/partitions.conf` |
| Query client | `slave/scripts/preflight/nodestatus_client.py` | `/home/smt/agents/scripts/preflight/nodestatus_client.py` |
| Exclusion bridge | `slave/scripts/preflight/node_exclude.py` | `/home/smt/agents/scripts/preflight/node_exclude.py` |
| Gateway config schema | `/home/code/nodestat/config/gateway.conf.example` | generated at deployment |
