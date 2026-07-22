#!/usr/bin/env bash
# Deploy Slave agent: OpenCode agents/skills and slave-only job scripts.
# Does NOT deploy monitor tools — use scripts/monitor/deploy-monitor.sh for those.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SLAVE_DIR="$ROOT/slave"
SHARED_DIR="$ROOT/shared"
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
    '$REMOTE_PROJECT/shared' \
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

# --- Config + shared ---
scp -o ConnectTimeout=15 \
  "$SLAVE_DIR/config/slave.conf" \
  "$GATEWAY:$REMOTE_PROJECT/config/"

scp -o ConnectTimeout=15 \
  "$SHARED_DIR/partitions.conf" \
  "$SHARED_DIR/slaves.conf" \
  "$SHARED_DIR/resolve-partition.py" \
  "$GATEWAY:$REMOTE_PROJECT/shared/"

# --- Runner + preflight ---
scp -o ConnectTimeout=15 \
  "$SLAVE_DIR/scripts/run-slave.sh" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/"

scp -o ConnectTimeout=15 \
  "$SLAVE_DIR/scripts/preflight/job_preflight.py" \
  "$SLAVE_DIR/scripts/preflight/node_exclude.py" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/preflight/"

ssh "$GATEWAY" "chmod +x \
  '$REMOTE_PROJECT/scripts/run-slave.sh' \
  '$REMOTE_PROJECT/scripts/preflight/job_preflight.py' \
  '$REMOTE_PROJECT/scripts/preflight/node_exclude.py' \
  '$REMOTE_PROJECT/shared/resolve-partition.py'"
echo "  $REMOTE_JOB_DIR inherits default umask from mkdir -p"

echo "== Done =="
echo "  OpenCode:    $GATEWAY:$REMOTE_PROJECT/.opencode/ (agents + skills)"
echo "  Job runner:  $GATEWAY:$REMOTE_PROJECT/scripts/run-slave.sh"
echo "  Preflight:   $GATEWAY:$REMOTE_PROJECT/scripts/preflight/"
echo "  Config:      $GATEWAY:$REMOTE_PROJECT/config/slave.conf"
echo "  Job store:   $GATEWAY:$REMOTE_JOB_DIR/"
