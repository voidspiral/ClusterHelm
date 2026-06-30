#!/usr/bin/env bash
# Memory monitor CLI — local node or partition-wide via run-slave.sh job flow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MONITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS_DIR="$ROOT/scripts/jobs"
MEMMON="$MONITOR_DIR/memmon.py"
RUN_SLAVE="$JOBS_DIR/run-slave.sh"
POLL_INTERVAL=2
POLL_MAX_ROUNDS=60

read_master_default() {
  local key="$1" fallback="$2"
  if [[ -f "$JOBS_DIR/master.conf" ]]; then
    local v
    v=$(grep -E "^${key}[[:space:]]" "$JOBS_DIR/master.conf" | awk '{print $2}' | head -1)
    [[ -n "$v" ]] && echo "$v" && return
  fi
  echo "$fallback"
}

usage() {
  echo "Usage: $0 local" >&2
  echo "       $0 partition PARTITION [--subset EXPR]" >&2
  exit 1
}

cmd_local() {
  python3 "$MEMMON"
}

cmd_partition() {
  local partition="" subset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subset) subset="$2"; shift 2 ;;
      -*) echo "Unknown option: $1" >&2; exit 1 ;;
      *)
        if [[ -z "$partition" ]]; then
          partition="$1"
        else
          echo "Unexpected argument: $1" >&2
          usage
        fi
        shift
        ;;
    esac
  done
  [[ -n "$partition" ]] || usage

  local target="$partition"
  if [[ -n "$subset" ]]; then
    target="$subset"
  fi

  local remote_project
  remote_project="$(read_master_default remote_project "$ROOT")"
  # Inline payload: memmon.py is only deployed on the gateway; cn2–cn10 run via --remote-cmd.
  local cmd
  cmd=$(python3 "$MEMMON" --remote-cmd)

  local out job_id
  out=$("$RUN_SLAVE" submit --partition "$target" --command "$cmd" --task "memory-monitor" 2>&1) || {
    echo "ERROR: submit failed: $out" >&2
    exit 1
  }
  job_id=$(echo "$out" | sed -n 's/^job_id=//p' | head -1)
  if [[ -z "$job_id" ]]; then
    echo "ERROR: no job_id in submit output: $out" >&2
    exit 1
  fi

  POLL_MAX_ROUNDS="$(read_master_default poll_max_rounds "$POLL_MAX_ROUNDS")"
  local backoff
  backoff="$(read_master_default poll_backoff "5,10,20,30")"
  local -a intervals
  IFS=',' read -ra intervals <<< "$backoff"

  local round=0 status="" job_json=""
  while (( round < POLL_MAX_ROUNDS )); do
    job_json=$("$RUN_SLAVE" poll --job-id "$job_id" 2>&1) || {
      echo "ERROR: poll failed for $job_id" >&2
      exit 1
    }
    status=$(echo "$job_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
    case "$status" in
      done|partial|failed) break ;;
    esac
    local wait="${intervals[$((round < ${#intervals[@]} ? round : ${#intervals[@]} - 1))]}"
    wait="${wait:-$POLL_INTERVAL}"
    sleep "$wait"
    ((round++)) || true
  done

  if [[ "$status" != "done" && "$status" != "partial" && "$status" != "failed" ]]; then
    echo "ERROR: job $job_id timed out (status=$status)" >&2
    exit 1
  fi

  local tmp_json
  tmp_json=$(mktemp)
  trap 'rm -f "$tmp_json"' RETURN
  printf '%s' "$job_json" > "$tmp_json"

  python3 - "$partition" "$job_id" "$status" "$tmp_json" <<'PY'
import json, sys

partition, job_id, status, path = sys.argv[1:5]
with open(path) as f:
    data = json.load(f)
nodes_out = []
parse_errors = []

for host, node in sorted(data.get("nodes", {}).items()):
    if node.get("state") != "ok" or node.get("phase") != "exec":
        continue
    raw = (node.get("stdout") or "").strip()
    if not raw:
        parse_errors.append(f"{host}: empty stdout")
        continue
    try:
        rec = json.loads(raw.split("\n")[0])
        nodes_out.append(rec)
    except json.JSONDecodeError:
        parse_errors.append(f"{host}: invalid JSON")

excluded = list(data.get("excluded_hosts", []))
excluded.extend(data.get("newly_excluded", []))
result = {
    "partition": data.get("partition", partition),
    "partition_nodeset": data.get("partition_nodeset"),
    "job_id": job_id,
    "status": status,
    "reachable": data.get("reachable_hosts", []),
    "excluded": sorted(set(excluded)),
    "unreachable": [
        h for h in data.get("nodes", {})
        if h not in data.get("reachable_hosts", [])
        and data["nodes"][h].get("state") != "excluded"
    ],
    "nodes": nodes_out,
}
if parse_errors:
    result["parse_errors"] = parse_errors

print(json.dumps(result, separators=(",", ":")))
PY
}

main="${1:-}"
shift || true
case "$main" in
  local) cmd_local "$@" ;;
  partition) cmd_partition "$@" ;;
  -h|--help|"") usage ;;
  *) echo "Unknown subcommand: $main" >&2; usage ;;
esac
