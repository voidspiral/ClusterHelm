#!/usr/bin/env bash
# Deploy Master agent: OpenCode agent and master-side job scripts.
# Default target is the local workspace ($ROOT). Pass a host to deploy over SSH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MASTER_DIR="$ROOT/master"
TARGET="${1:-local}"
REMOTE_PROJECT="/home/smt/agents"

usage() {
  echo "Usage: $0 [HOST|local]" >&2
  echo "  local (default) — install master-agent into this workspace" >&2
  echo "  HOST            — SSH deploy to a remote Master host" >&2
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

deploy_local() {
  echo "== Deploy master agent (local: $ROOT) =="

  mkdir -p "$ROOT/var/agent-jobs"

  if [[ -f "$MASTER_DIR/.opencode/agents/master-agent.md" ]]; then
    echo "  OpenCode:    $MASTER_DIR/.opencode/agents/master-agent.md"
  else
    echo "WARN: missing $MASTER_DIR/.opencode/agents/master-agent.md" >&2
  fi

  if [[ -f "$MASTER_DIR/opencode.json" ]]; then
    echo "  OpenCode cfg: $MASTER_DIR/opencode.json (default_agent=master-agent)"
  fi

  chmod +x \
    "$MASTER_DIR/scripts/submit.sh" \
    "$MASTER_DIR/scripts/poll.sh" \
    "$MASTER_DIR/scripts/poll-wait.sh" \
    "$MASTER_DIR/scripts/list-slaves.py" \
    2>/dev/null || true

  if command -v opencode >/dev/null 2>&1; then
    echo "  OpenCode:    $(command -v opencode)"
    opencode agent list 2>/dev/null | grep -q 'master-agent' && echo "  OpenCode agent: master-agent" || true
  else
    echo "  WARN: opencode CLI not in PATH" >&2
  fi

  echo "== Done =="
  echo "  Job scripts: $MASTER_DIR/scripts/submit.sh, poll.sh, poll-wait.sh"
  echo "  Config:      $MASTER_DIR/config/{master,partitions,slaves}.conf"
  echo "  Job store:   $ROOT/var/agent-jobs/"
}

deploy_remote() {
  local host="$1"
  echo "== Deploy master agent to $host =="

  ssh -o ConnectTimeout=15 "$host" \
    "mkdir -p '$REMOTE_PROJECT/.opencode/agents' \
      '$REMOTE_PROJECT/scripts' \
      '$REMOTE_PROJECT/config' \
      '$REMOTE_PROJECT/var/agent-jobs'"

  scp -o ConnectTimeout=15 -r \
    "$MASTER_DIR/.opencode/"* \
    "$host:$REMOTE_PROJECT/.opencode/"
  echo "  OpenCode:    $host:$REMOTE_PROJECT/.opencode/"

  scp -o ConnectTimeout=15 \
    "$MASTER_DIR/opencode.json" \
    "$host:$REMOTE_PROJECT/opencode.json"
  echo "  OpenCode cfg: $host:$REMOTE_PROJECT/opencode.json"

  scp -o ConnectTimeout=15 \
    "$MASTER_DIR/config/master.conf" \
    "$MASTER_DIR/config/partitions.conf" \
    "$MASTER_DIR/config/slaves.conf" \
    "$host:$REMOTE_PROJECT/config/"

  scp -o ConnectTimeout=15 \
    "$MASTER_DIR/scripts/submit.sh" \
    "$MASTER_DIR/scripts/poll.sh" \
    "$MASTER_DIR/scripts/poll-wait.sh" \
    "$MASTER_DIR/scripts/list-slaves.py" \
    "$host:$REMOTE_PROJECT/scripts/"

  ssh "$host" "chmod +x \
    '$REMOTE_PROJECT/scripts/submit.sh' \
    '$REMOTE_PROJECT/scripts/poll.sh' \
    '$REMOTE_PROJECT/scripts/poll-wait.sh' \
    '$REMOTE_PROJECT/scripts/list-slaves.py'"

  echo "== Done =="
  echo "  OpenCode:    $host:$REMOTE_PROJECT/.opencode/agents/master-agent.md"
  echo "  Job scripts: $host:$REMOTE_PROJECT/scripts/"
  echo "  Config:      $host:$REMOTE_PROJECT/config/"
}

if [[ "$TARGET" == "local" ]]; then
  deploy_local
else
  deploy_remote "$TARGET"
fi
