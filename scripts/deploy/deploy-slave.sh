#!/usr/bin/env bash
# Deploy Slave agent, deterministic workflows, and their runtime scripts.
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
    '$REMOTE_PROJECT/scripts/workflows' \
    '$REMOTE_PROJECT/scripts/monitor' \
    '$REMOTE_PROJECT/scripts/mpi' \
    '$REMOTE_PROJECT/tests/mpi' \
    '$REMOTE_PROJECT/workflows' \
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

scp -o ConnectTimeout=15 \
  "$SLAVE_DIR/scripts/workflows/workflow_runner.py" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/workflows/"

scp -o ConnectTimeout=15 \
  "$SLAVE_DIR/workflows/"*.json \
  "$GATEWAY:$REMOTE_PROJECT/workflows/"

# Workflow implementations are deployed with the runner so a catalog entry
# cannot drift from the executable it references.
scp -o ConnectTimeout=15 \
  "$ROOT/scripts/monitor/mem-api.sh" \
  "$ROOT/scripts/monitor/memmon.py" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/monitor/"

scp -o ConnectTimeout=15 \
  "$ROOT/scripts/mpi/run-fullcore-test.sh" \
  "$ROOT/scripts/mpi/cleanup-mpi.sh" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/mpi/"

scp -o ConnectTimeout=15 \
  "$ROOT/tests/mpi/fullcore_test.c" \
  "$GATEWAY:$REMOTE_PROJECT/tests/mpi/"

ssh "$GATEWAY" "chmod +x \
  '$REMOTE_PROJECT/scripts/run-slave.sh' \
  '$REMOTE_PROJECT/scripts/resolve-partition.py' \
  '$REMOTE_PROJECT/scripts/preflight/job_preflight.py' \
  '$REMOTE_PROJECT/scripts/preflight/node_exclude.py' \
  '$REMOTE_PROJECT/scripts/workflows/workflow_runner.py' \
  '$REMOTE_PROJECT/scripts/monitor/mem-api.sh' \
  '$REMOTE_PROJECT/scripts/monitor/memmon.py' \
  '$REMOTE_PROJECT/scripts/mpi/run-fullcore-test.sh' \
  '$REMOTE_PROJECT/scripts/mpi/cleanup-mpi.sh'"
echo "  $REMOTE_JOB_DIR inherits default umask from mkdir -p"

echo "== Done =="
echo "  OpenCode:    $GATEWAY:$REMOTE_PROJECT/.opencode/ (agents + skills)"
echo "  Job runner:  $GATEWAY:$REMOTE_PROJECT/scripts/run-slave.sh"
echo "  Workflows:   $GATEWAY:$REMOTE_PROJECT/workflows/"
echo "  Preflight:   $GATEWAY:$REMOTE_PROJECT/scripts/preflight/"
echo "  Config:      $GATEWAY:$REMOTE_PROJECT/config/{slave,partitions}.conf"
echo "  Job store:   $GATEWAY:$REMOTE_JOB_DIR/"
