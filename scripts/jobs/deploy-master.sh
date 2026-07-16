#!/usr/bin/env bash
# Deploy Master agent: OpenCode agent and master-side job scripts.
# Default target is the local workspace ($ROOT). Pass a host to deploy over SSH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS_DIR="$(cd "$(dirname "$0")" && pwd)"
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

  mkdir -p "$ROOT/.opencode/agents" "$ROOT/var/agent-jobs"

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
    "$JOBS_DIR/poll-wait.sh" \
    "$JOBS_DIR/list-slaves.py" \
    "$JOBS_DIR/resolve-partition.py" \
    2>/dev/null || true

  if command -v opencode >/dev/null 2>&1; then
    echo "  OpenCode:    $(command -v opencode)"
    opencode agent list 2>/dev/null | grep -q 'master-agent' && echo "  OpenCode agent: master-agent" || true
  else
    echo "  WARN: opencode CLI not in PATH" >&2
  fi

  echo "== Done =="
  echo "  Job scripts: $JOBS_DIR/submit.sh, poll.sh, poll-wait.sh"
  echo "  Job store:   $ROOT/var/agent-jobs/"
}

deploy_remote() {
  local host="$1"
  echo "== Deploy master agent to $host =="

  ssh -o ConnectTimeout=15 "$host" \
    "mkdir -p '$REMOTE_PROJECT/.opencode/agents' '$REMOTE_PROJECT/scripts/jobs' '$REMOTE_PROJECT/var/agent-jobs'"

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
    "$JOBS_DIR/poll-wait.sh" \
    "$JOBS_DIR/master.conf" \
    "$JOBS_DIR/partitions.conf" \
    "$JOBS_DIR/slaves.conf" \
    "$JOBS_DIR/list-slaves.py" \
    "$JOBS_DIR/resolve-partition.py" \
    "$host:$REMOTE_PROJECT/scripts/jobs/"

  ssh "$host" "chmod +x \
    '$REMOTE_PROJECT/scripts/jobs/submit.sh' \
    '$REMOTE_PROJECT/scripts/jobs/poll.sh' \
    '$REMOTE_PROJECT/scripts/jobs/poll-wait.sh' \
    '$REMOTE_PROJECT/scripts/jobs/list-slaves.py' \
    '$REMOTE_PROJECT/scripts/jobs/resolve-partition.py'"

  echo "== Done =="
  echo "  OpenCode:    $host:$REMOTE_PROJECT/.opencode/agents/master-agent.md"
  echo "  Job scripts: $host:$REMOTE_PROJECT/scripts/jobs/"
}

if [[ "$TARGET" == "local" ]]; then
  deploy_local
else
  deploy_remote "$TARGET"
fi
