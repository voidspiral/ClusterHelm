#!/usr/bin/env bash
# Master-side: single blocking poll (SSH → run-slave.sh wait). Returns when job is terminal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Monorepo: var/ at repo root; deployed flat: var/ next to scripts/
if [[ -d "$MASTER_ROOT/../slave" ]]; then
  ROOT="$(cd "$MASTER_ROOT/.." && pwd)"
else
  ROOT="$MASTER_ROOT"
fi
CONFIG="$MASTER_ROOT/config/master.conf"
GATEWAY=""
JOB_ID=""
TIMEOUT=""
TIMEOUT_SET=0

read_master_default() {
  local key="$1" fallback="$2"
  if [[ -f "$CONFIG" ]]; then
    local v
    v=$(grep -E "^${key}[[:space:]]" "$CONFIG" | awk '{print $2}' | head -1)
    [[ -n "$v" ]] && echo "$v" && return
  fi
  echo "$fallback"
}

usage() {
  echo "Usage: $0 --job-id ID [--gateway HOST] [--timeout SEC]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway) GATEWAY="$2"; shift 2 ;;
    --job-id) JOB_ID="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; TIMEOUT_SET=1; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$JOB_ID" ]] || usage

GATEWAY="${GATEWAY:-$(read_master_default default_gateway cn1)}"
DEFAULT_DEADLINE="$(read_master_default default_deadline 1800)"
WAIT_SLACK="$(read_master_default wait_slack 30)"
if [[ "$TIMEOUT_SET" -eq 0 ]]; then
  TIMEOUT=$((DEFAULT_DEADLINE + WAIT_SLACK))
fi
REMOTE_PROJECT="$(read_master_default remote_project "")"
[[ -n "$REMOTE_PROJECT" ]] || { echo "ERROR: set remote_project in $CONFIG" >&2; exit 1; }
REMOTE_RUN_SLAVE="$(read_master_default remote_run_slave scripts/run-slave.sh)"
REMOTE_SCRIPT="${REMOTE_PROJECT}/${REMOTE_RUN_SLAVE}"
SSH_ALIVE="$(read_master_default ssh_server_alive_interval 30)"
SSH_ALIVE_MAX="$(read_master_default ssh_server_alive_count_max 3)"

# Single SSH call: gateway blocks until completion signal (or safety timeout)
out=$(ssh -o ConnectTimeout="$(read_master_default ssh_connect_timeout 15)" \
  -o ServerAliveInterval="$SSH_ALIVE" \
  -o ServerAliveCountMax="$SSH_ALIVE_MAX" \
  -o BatchMode=yes "$GATEWAY" \
  "bash '$REMOTE_SCRIPT' wait --job-id $(printf %q "$JOB_ID") --timeout $TIMEOUT" 2>&1) || {
  echo "ERROR: wait on $GATEWAY failed: $out" >&2
  exit 1
}

echo "$out"
mkdir -p "$ROOT/var/agent-jobs"
echo "$out" > "$ROOT/var/agent-jobs/${JOB_ID}.last.json"

# Parse status for exit code
status=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "?")
report=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('partition_report',{}).get('markdown',''))" 2>/dev/null || true)
echo "status=$status" >&2
if [[ -n "$report" ]]; then
  echo "--- partition_report ---" >&2
  echo "$report" >&2
fi

case "$status" in
  done|partial) exit 0 ;;
  *) exit 1 ;;
esac
