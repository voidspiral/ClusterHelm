#!/usr/bin/env bash
# Deploy Slave agent: OpenCode agents/skills and slave-only job scripts.
# Does NOT deploy monitor tools — use scripts/monitor/deploy-monitor.sh for those.
# partitions.conf is copied from Master SoT (master/config/) — Slave does not own slaves.conf.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SLAVE_DIR="$ROOT/slave"
MASTER_CONFIG="$ROOT/master/config"
GATEWAY="${1:-cn1}"
REMOTE_PROJECT="/home/smt/agents"
REMOTE_JOB_DIR="$REMOTE_PROJECT/var/agent-jobs"

echo "opencode src: $SLAVE_DIR/.opencode"
echo "opencode cn1: $REMOTE_PROJECT/.opencode"

echo "== Deploy slave agent to $GATEWAY =="

ssh -o ConnectTimeout=15 "$GATEWAY" \
  "mkdir -p '$REMOTE_JOB_DIR' \
    '$REMOTE_PROJECT/scripts/preflight' \
    '$REMOTE_PROJECT/config' \
    '$REMOTE_PROJECT/.opencode'"

# --- OpenCode agents + skills ---
if [[ -d "$SLAVE_DIR/.opencode" ]]; then
  scp -o ConnectTimeout=15 -r \
    "$SLAVE_DIR/.opencode/"* \
    "$GATEWAY:$REMOTE_PROJECT/.opencode/"
  echo "  OpenCode:    $GATEWAY:$REMOTE_PROJECT/.opencode/"
fi
if [[ -f "$SLAVE_DIR/opencode.json" ]]; then
  scp -o ConnectTimeout=15 \
    "$SLAVE_DIR/opencode.json" \
    "$GATEWAY:$REMOTE_PROJECT/opencode.json"
  echo "  OpenCode cfg: $GATEWAY:$REMOTE_PROJECT/opencode.json (default_agent=slave-agent)"
fi

# --- Config: slave.conf + partitions.conf (from Master SoT) ---
scp -o ConnectTimeout=15 \
  "$SLAVE_DIR/config/slave.conf" \
  "$MASTER_CONFIG/partitions.conf" \
  "$GATEWAY:$REMOTE_PROJECT/config/"

# --- Runner + resolve-partition + preflight ---
scp -o ConnectTimeout=15 \
  "$SLAVE_DIR/scripts/run-slave.sh" \
  "$SLAVE_DIR/scripts/resolve-partition.py" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/"

scp -o ConnectTimeout=15 \
  "$SLAVE_DIR/scripts/preflight/job_preflight.py" \
  "$SLAVE_DIR/scripts/preflight/node_exclude.py" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/preflight/"

ssh "$GATEWAY" "chmod +x \
  '$REMOTE_PROJECT/scripts/run-slave.sh' \
  '$REMOTE_PROJECT/scripts/resolve-partition.py' \
  '$REMOTE_PROJECT/scripts/preflight/job_preflight.py' \
  '$REMOTE_PROJECT/scripts/preflight/node_exclude.py'"
echo "  $REMOTE_JOB_DIR inherits default umask from mkdir -p"

echo "== Done =="
echo "  OpenCode:    $GATEWAY:$REMOTE_PROJECT/.opencode/ (agents + skills)"
echo "  Job runner:  $GATEWAY:$REMOTE_PROJECT/scripts/run-slave.sh"
echo "  Preflight:   $GATEWAY:$REMOTE_PROJECT/scripts/preflight/"
echo "  Config:      $GATEWAY:$REMOTE_PROJECT/config/{slave,partitions}.conf"
echo "  Job store:   $GATEWAY:$REMOTE_JOB_DIR/"
