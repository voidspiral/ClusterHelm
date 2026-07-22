#!/usr/bin/env bash
# Deploy memory monitor CLI on the Slave gateway (optional; not part of deploy-slave.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MONITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER_CONF="$ROOT/master/config/master.conf"
GATEWAY="${1:-cn1}"
REMOTE_PROJECT="/home/smt/agents"

echo "== Deploy memory monitor to $GATEWAY =="

ssh -o ConnectTimeout=15 "$GATEWAY" \
  "mkdir -p '$REMOTE_PROJECT/scripts/monitor' '$REMOTE_PROJECT/config'"

scp -o ConnectTimeout=15 \
  "$MONITOR_DIR/memmon.py" \
  "$MONITOR_DIR/mem-api.sh" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/monitor/"

# mem-api.sh reads poll_backoff / remote_project from master.conf when present
if [[ -f "$MASTER_CONF" ]]; then
  scp -o ConnectTimeout=15 \
    "$MASTER_CONF" \
    "$GATEWAY:$REMOTE_PROJECT/config/master.conf"
fi

ssh "$GATEWAY" "chmod +x \
  '$REMOTE_PROJECT/scripts/monitor/memmon.py' \
  '$REMOTE_PROJECT/scripts/monitor/mem-api.sh'"

echo "== Done =="
echo "  Memory CLI:  $GATEWAY:$REMOTE_PROJECT/scripts/monitor/mem-api.sh"
echo "  Note:       partition jobs use memmon.py --remote-cmd; cn2–cn10 need no file until per-node API exists"
