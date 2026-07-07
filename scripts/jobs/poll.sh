#!/usr/bin/env bash
# Master-side: poll job status from slave gateway.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY=""
JOB_ID=""

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
  echo "Usage: $0 --job-id ID [--gateway HOST]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway) GATEWAY="$2"; shift 2 ;;
    --job-id) JOB_ID="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$JOB_ID" ]] || usage

GATEWAY="${GATEWAY:-$(read_master_default default_gateway cn1)}"
POLL_TIMEOUT="$(read_master_default poll_timeout 15)"
REMOTE_PROJECT="$(read_master_default remote_project /home/code/agents)"
REMOTE_SCRIPT="${REMOTE_PROJECT}/scripts/jobs/run-slave.sh"

out=$(ssh -o ConnectTimeout="$(read_master_default ssh_connect_timeout 15)" -o BatchMode=yes "$GATEWAY" \
  "timeout $POLL_TIMEOUT bash '$REMOTE_SCRIPT' poll --job-id $(printf %q "$JOB_ID")" 2>&1) || {
  echo "ERROR: poll on $GATEWAY failed: $out" >&2
  exit 1
}

# stdout: JSON only (safe for redirects / json.load(sys.stdin))
echo "$out"
mkdir -p "$ROOT/var/agent-jobs"
echo "$out" > "$ROOT/var/agent-jobs/${JOB_ID}.last.json"

status=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "?")
report=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('partition_report',{}).get('markdown',''))" 2>/dev/null || true)
# human-readable summary on stderr — do not mix into stdout JSON
echo "status=$status" >&2
if [[ -n "$report" ]]; then
  echo "--- partition_report ---" >&2
  echo "$report" >&2
fi
