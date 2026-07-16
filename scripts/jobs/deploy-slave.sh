#!/usr/bin/env bash
# Deploy Slave agent: OpenCode agents/skills and slave-only job scripts.
# Does NOT deploy monitor tools — use scripts/monitor/deploy-monitor.sh for those.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY="${1:-cn1}"
REMOTE_PROJECT="/home/smt/agents"
REMOTE_JOB_DIR="$REMOTE_PROJECT/var/agent-jobs"
DEPLOY_SRC="$ROOT/deploy/slave-agent"
OPENCODE_SRC="$DEPLOY_SRC/.opencode"

echo "opencode src: $OPENCODE_SRC"
echo "opencode cn1: $REMOTE_PROJECT/.opencode"

echo "== Deploy slave agent to $GATEWAY =="

ssh -o ConnectTimeout=15 "$GATEWAY" \
  "mkdir -p  '$REMOTE_JOB_DIR' '$REMOTE_PROJECT/scripts/jobs' '$REMOTE_PROJECT/.opencode'"

# --- OpenCode agents + skills (deploy/slave-agent/.opencode/*) ---
if [[ -d "$OPENCODE_SRC" ]]; then
  scp -o ConnectTimeout=15 -r \
    "$OPENCODE_SRC/"* \
    "$GATEWAY:$REMOTE_PROJECT/.opencode/"
  echo "  OpenCode:    $GATEWAY:$REMOTE_PROJECT/.opencode/"
fi
if [[ -f "$DEPLOY_SRC/opencode.json" ]]; then
  scp -o ConnectTimeout=15 \
    "$DEPLOY_SRC/opencode.json" \
    "$GATEWAY:$REMOTE_PROJECT/opencode.json"
  echo "  OpenCode cfg: $GATEWAY:$REMOTE_PROJECT/opencode.json (default_agent=slave-agent)"
fi

# --- Slave-agent job runner + partition config ---
scp -o ConnectTimeout=15 \
  "$JOBS_DIR/run-slave.sh" \
  "$JOBS_DIR/slaves.conf" \
  "$JOBS_DIR/partitions.conf" \
  "$JOBS_DIR/resolve-partition.py" \
  "$JOBS_DIR/slave.conf" \
  "$JOBS_DIR/node_exclude.py" \
  "$JOBS_DIR/job_preflight.py" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/jobs/"

ssh "$GATEWAY" "chmod +x \
  '$REMOTE_PROJECT/scripts/jobs/run-slave.sh' \
  '$REMOTE_PROJECT/scripts/jobs/resolve-partition.py' \
  '$REMOTE_PROJECT/scripts/jobs/job_preflight.py'"
echo "  $REMOTE_JOB_DIR inherits default umask from mkdir -p"

echo "== Done =="
echo "  OpenCode:    $GATEWAY:$REMOTE_PROJECT/.opencode/ (agents + skills)"
echo "  Job runner:  $GATEWAY:$REMOTE_PROJECT/scripts/jobs/run-slave.sh"
echo "  Job store:   $GATEWAY:$REMOTE_JOB_DIR/"
