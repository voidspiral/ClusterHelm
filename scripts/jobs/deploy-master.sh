#!/usr/bin/env bash
# Deploy Master agent: Cursor rules, OpenCode agent, and master-side job scripts.
# Default target is the local workspace ($ROOT). Pass a host to deploy over SSH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-local}"
REMOTE_RULES_DIR="/root/.cursor/rules"
REMOTE_PROJECT="/home/code/agents"

usage() {
  echo "Usage: $0 [HOST|local]" >&2
  echo "  local (default) — install master-agent into this workspace + ~/.cursor/rules" >&2
  echo "  HOST            — SSH deploy to a remote Master host" >&2
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

deploy_local() {
  echo "== Deploy master agent (local: $ROOT) =="

  mkdir -p "$ROOT/.opencode/agents" "$ROOT/.cursor/rules" "$ROOT/var/agent-jobs"

  if [[ -f "$ROOT/.cursor/rules/master-agent.mdc" ]]; then
    mkdir -p "$HOME/.cursor/rules"
    cp "$ROOT/.cursor/rules/master-agent.mdc" "$HOME/.cursor/rules/master-agent.mdc"
    echo "  Cursor rule: $HOME/.cursor/rules/master-agent.mdc"
  else
    echo "WARN: missing $ROOT/.cursor/rules/master-agent.mdc" >&2
  fi

  if [[ -f "$ROOT/.opencode/agents/master-agent.md" ]]; then
    echo "  OpenCode:    $ROOT/.opencode/agents/master-agent.md"
  else
    echo "WARN: missing $ROOT/.opencode/agents/master-agent.md" >&2
  fi

  if [[ -f "$ROOT/opencode.json" ]]; then
    echo "  OpenCode cfg: $ROOT/opencode.json (default_agent=master-agent)"
  fi

  chmod +x \
    "$JOBS_DIR/submit.sh" \
    "$JOBS_DIR/poll.sh" \
    "$JOBS_DIR/list-slaves.py" \
    "$JOBS_DIR/resolve-partition.py" \
    2>/dev/null || true

  if command -v agent >/dev/null 2>&1; then
    echo "  Cursor agent: $(command -v agent) ($(agent --version 2>/dev/null || echo unknown))"
  else
    echo "  WARN: Cursor agent CLI not in PATH" >&2
  fi
  if command -v opencode >/dev/null 2>&1; then
    echo "  OpenCode:    $(command -v opencode)"
    opencode agent list 2>/dev/null | grep -q 'master-agent' && echo "  OpenCode agent: master-agent" || true
  else
    echo "  WARN: opencode CLI not in PATH" >&2
  fi

  echo "== Done =="
  echo "  Job scripts: $JOBS_DIR/submit.sh, poll.sh"
  echo "  Job store:   $ROOT/var/agent-jobs/"
}

deploy_remote() {
  local host="$1"
  echo "== Deploy master agent to $host =="

  ssh -o ConnectTimeout=15 "$host" \
    "mkdir -p '$REMOTE_RULES_DIR' '$REMOTE_PROJECT/.opencode/agents' '$REMOTE_PROJECT/.cursor/rules' '$REMOTE_PROJECT/scripts/jobs' '$REMOTE_PROJECT/var/agent-jobs'"

  scp -o ConnectTimeout=15 \
    "$ROOT/.cursor/rules/master-agent.mdc" \
    "$host:$REMOTE_RULES_DIR/master-agent.mdc"
  echo "  Cursor rule: $host:$REMOTE_RULES_DIR/master-agent.mdc"

  scp -o ConnectTimeout=15 \
    "$ROOT/.opencode/agents/master-agent.md" \
    "$host:$REMOTE_PROJECT/.opencode/agents/master-agent.md"
  echo "  OpenCode:    $host:$REMOTE_PROJECT/.opencode/agents/master-agent.md"

  scp -o ConnectTimeout=15 \
    "$ROOT/opencode.json" \
    "$host:$REMOTE_PROJECT/opencode.json"
  echo "  OpenCode cfg: $host:$REMOTE_PROJECT/opencode.json"

  scp -o ConnectTimeout=15 \
    "$JOBS_DIR/submit.sh" \
    "$JOBS_DIR/poll.sh" \
    "$JOBS_DIR/master.conf" \
    "$JOBS_DIR/partitions.conf" \
    "$JOBS_DIR/slaves.conf" \
    "$JOBS_DIR/list-slaves.py" \
    "$JOBS_DIR/resolve-partition.py" \
    "$host:$REMOTE_PROJECT/scripts/jobs/"

  ssh "$host" "chmod +x \
    '$REMOTE_PROJECT/scripts/jobs/submit.sh' \
    '$REMOTE_PROJECT/scripts/jobs/poll.sh' \
    '$REMOTE_PROJECT/scripts/jobs/list-slaves.py' \
    '$REMOTE_PROJECT/scripts/jobs/resolve-partition.py'"

  ssh "$host" 'python3 - <<'"'"'PY'"'"'
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
  echo "  Master rule: $host:$REMOTE_RULES_DIR/master-agent.mdc"
  echo "  OpenCode:    $host:$REMOTE_PROJECT/.opencode/agents/master-agent.md"
  echo "  Job scripts: $host:$REMOTE_PROJECT/scripts/jobs/"
}

if [[ "$TARGET" == "local" ]]; then
  deploy_local
else
  deploy_remote "$TARGET"
fi
