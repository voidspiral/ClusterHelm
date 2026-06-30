#!/usr/bin/env bash
# Deploy memory monitor CLI on the Slave gateway (optional; not part of deploy-slave.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MONITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS_DIR="$ROOT/scripts/jobs"
GATEWAY="${1:-cn1}"
REMOTE_PROJECT="/home/code/agents"

echo "== Deploy memory monitor to $GATEWAY =="

ssh -o ConnectTimeout=15 "$GATEWAY" \
  "mkdir -p '$REMOTE_PROJECT/scripts/monitor' '$REMOTE_PROJECT/scripts/jobs'"

scp -o ConnectTimeout=15 \
  "$MONITOR_DIR/memmon.py" \
  "$MONITOR_DIR/mem-api.sh" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/monitor/"

# mem-api.sh reads poll_backoff / remote_project from master.conf when present
scp -o ConnectTimeout=15 \
  "$JOBS_DIR/master.conf" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/jobs/"

ssh "$GATEWAY" "chmod +x \
  '$REMOTE_PROJECT/scripts/monitor/memmon.py' \
  '$REMOTE_PROJECT/scripts/monitor/mem-api.sh'"

echo "== Done =="
echo "  Memory CLI:  $GATEWAY:$REMOTE_PROJECT/scripts/monitor/mem-api.sh"
echo "  Note:       partition jobs use memmon.py --remote-cmd; cn2–cn10 need no file until per-node API exists"
