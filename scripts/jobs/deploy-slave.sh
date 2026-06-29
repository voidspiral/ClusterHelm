#!/usr/bin/env bash
# Deploy slave-agent.md and job scripts to cn1 global paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATEWAY="${1:-cn1}"
REMOTE_RULES_DIR="/root/.cursor/rules"
REMOTE_JOB_DIR="/var/agent-jobs"
REMOTE_PROJECT="/home/code/agents"

echo "== Deploy slave agent to $GATEWAY =="

ssh -o ConnectTimeout=15 "$GATEWAY" "mkdir -p '$REMOTE_RULES_DIR' '$REMOTE_JOB_DIR' '$REMOTE_PROJECT/scripts/jobs'"

scp -o ConnectTimeout=15 \
  "$ROOT/deploy/cn1/.cursor/rules/slave-agent.mdc" \
  "$GATEWAY:$REMOTE_RULES_DIR/slave-agent.mdc"

scp -o ConnectTimeout=15 \
  "$ROOT/scripts/jobs/run-slave.sh" \
  "$ROOT/scripts/jobs/slaves.conf" \
  "$ROOT/scripts/jobs/partitions.conf" \
  "$ROOT/scripts/jobs/resolve-partition.py" \
  "$ROOT/scripts/jobs/list-slaves.py" \
  "$ROOT/scripts/jobs/master.conf" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/jobs/"

ssh "$GATEWAY" "chmod +x '$REMOTE_PROJECT/scripts/jobs/run-slave.sh' '$REMOTE_PROJECT/scripts/jobs/resolve-partition.py' && chmod 755 '$REMOTE_JOB_DIR'"

# Ensure Cursor CLI network: HTTP/2 + shell permissions for automation
ssh "$GATEWAY" 'python3 - <<'"'"'PY'"'"'
import json, os
p = os.path.expanduser("~/.cursor/cli-config.json")
if os.path.isfile(p):
    with open(p) as f: cfg = json.load(f)
else:
    cfg = {}
cfg.setdefault("network", {})["useHttp1ForAgent"] = False
cfg["approvalMode"] = "allowlist"
cfg.setdefault("permissions", {})["allow"] = ["Shell(*)"]
with open(p, "w") as f: json.dump(cfg, f, indent=2)
print("cli-config updated")
PY'

echo "== Done =="
echo "  Slave rule:  $GATEWAY:$REMOTE_RULES_DIR/slave-agent.mdc"
echo "  Job runner:  $GATEWAY:$REMOTE_PROJECT/scripts/jobs/run-slave.sh"
echo "  Job store:   $GATEWAY:$REMOTE_JOB_DIR/"
