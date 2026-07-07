#!/usr/bin/env bash
# Deploy Slave agent: Cursor rules, OpenCode agents/skills, project skills, and slave-only job scripts.
# Does NOT deploy monitor tools — use scripts/monitor/deploy-monitor.sh for those.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY="${1:-cn1}"
REMOTE_RULES_DIR="/root/.cursor/rules"
REMOTE_JOB_DIR="/var/agent-jobs"
REMOTE_PROJECT="/home/code/agents"
DEPLOY_SRC="$ROOT/deploy/slave-agent"
RULES_SRC="$DEPLOY_SRC/.cursor/rules"
SKILLS_SRC="$DEPLOY_SRC/.cursor/skills"
OPENCODE_SRC="$DEPLOY_SRC/.opencode"

echo "== Deploy slave agent to $GATEWAY =="

ssh -o ConnectTimeout=15 "$GATEWAY" \
  "mkdir -p '$REMOTE_RULES_DIR' '$REMOTE_JOB_DIR' '$REMOTE_PROJECT/scripts/jobs' '$REMOTE_PROJECT/.opencode'"

# --- Cursor rules (agent behavior) ---
if [[ -f "$RULES_SRC/slave-agent.mdc" ]]; then
  scp -o ConnectTimeout=15 \
    "$RULES_SRC/slave-agent.mdc" \
    "$GATEWAY:$REMOTE_RULES_DIR/slave-agent.mdc"
else
  echo "WARN: missing $RULES_SRC/slave-agent.mdc" >&2
fi

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

# --- Project skills (deploy/slave-agent/.cursor/skills/*) ---
if [[ -d "$SKILLS_SRC" ]]; then
  ssh -o ConnectTimeout=15 "$GATEWAY" "mkdir -p '$REMOTE_PROJECT/.cursor/skills'"
  for skill_dir in "$SKILLS_SRC"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name=$(basename "$skill_dir")
    scp -o ConnectTimeout=15 -r \
      "$skill_dir" \
      "$GATEWAY:$REMOTE_PROJECT/.cursor/skills/$skill_name"
    echo "  Cursor skill: $skill_name"
  done
fi

# --- Slave-agent job runner + partition config ---
scp -o ConnectTimeout=15 \
  "$JOBS_DIR/run-slave.sh" \
  "$JOBS_DIR/slaves.conf" \
  "$JOBS_DIR/partitions.conf" \
  "$JOBS_DIR/resolve-partition.py" \
  "$JOBS_DIR/slave.conf" \
  "$JOBS_DIR/node_exclude.py" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/jobs/"

ssh "$GATEWAY" "chmod +x \
  '$REMOTE_PROJECT/scripts/jobs/run-slave.sh' \
  '$REMOTE_PROJECT/scripts/jobs/resolve-partition.py' \
  && chmod 755 '$REMOTE_JOB_DIR'"

# Cursor CLI: HTTP/2 + shell permissions for automation on gateway
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

# Cursor Agent CLI: ensure /root/.local/bin is on PATH for non-login SSH shells
ssh "$GATEWAY" 'bash -s' <<'REMOTE'
PATH_LINE='export PATH="/root/.local/bin:$PATH"'
for rc in /root/.bashrc /root/.profile; do
  touch "$rc"
  if ! grep -qF '/root/.local/bin' "$rc" 2>/dev/null; then
    echo "$PATH_LINE" >> "$rc"
    echo "  PATH added to $rc"
  fi
done
if [[ -x /root/.local/bin/agent ]]; then
  echo "  Cursor agent: /root/.local/bin/agent ($(/root/.local/bin/agent --version 2>/dev/null || echo unknown))"
else
  echo "  WARN: /root/.local/bin/agent not found" >&2
fi
REMOTE

echo "== Done =="
echo "  Slave rule:  $GATEWAY:$REMOTE_RULES_DIR/slave-agent.mdc"
echo "  Cursor agent:$GATEWAY:/root/.local/bin/agent (PATH via .bashrc/.profile)"
echo "  OpenCode:    $GATEWAY:$REMOTE_PROJECT/.opencode/ (agents + skills)"
echo "  Cursor skill:$GATEWAY:$REMOTE_PROJECT/.cursor/skills/"
echo "  Job runner:  $GATEWAY:$REMOTE_PROJECT/scripts/jobs/run-slave.sh"
echo "  Job store:   $GATEWAY:$REMOTE_JOB_DIR/"
