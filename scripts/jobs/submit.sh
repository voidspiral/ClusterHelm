#!/usr/bin/env bash
# Master-side: submit async job to a slave gateway.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY=""
PARTITION=""
COMMAND=""
PROMPT=""
RUNTIME=""
TASK_TITLE=""
DEADLINE_SEC=1800

read_master_default() {
  local key="$1" fallback="$2"
  if [[ -f "$JOBS_DIR/master.conf" ]]; then
    local v
    v=$(grep -E "^${key}[[:space:]]" "$JOBS_DIR/master.conf" | awk '{print $2}' | head -1)
    [[ -n "$v" ]] && echo "$v" && return
  fi
  echo "$fallback"
}

usage() {
  echo "Usage: $0 --partition EXPR (--command CMD | --prompt TASK) [--task TITLE] [--gateway HOST] [--deadline SEC] [--runtime auto|cursor|opencode]" >&2
  echo "  Job = one decomposed task delegated to a slave (not limited to MPI)." >&2
  echo "  --command  script mode: slave runs the command verbatim on each node" >&2
  echo "  --prompt   agent mode: gateway launches the Slave agent CLI with the task (agent-to-agent)" >&2
  echo "  --runtime  agent CLI on gateway; default from gateway slave.conf (auto)" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway) GATEWAY="$2"; shift 2 ;;
    --partition) PARTITION="$2"; shift 2 ;;
    --command) COMMAND="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --task) TASK_TITLE="$2"; shift 2 ;;
    --deadline) DEADLINE_SEC="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$PARTITION" && ( -n "$COMMAND" || -n "$PROMPT" ) ]] || usage

GATEWAY="${GATEWAY:-$(python3 "$JOBS_DIR/list-slaves.py" --partition "$PARTITION" 2>/dev/null || read_master_default default_gateway cn1)}"
SUBMIT_TIMEOUT="$(read_master_default submit_timeout 30)"
REMOTE_PROJECT="$(read_master_default remote_project /home/code/agents)"
REMOTE_SCRIPT="${REMOTE_PROJECT}/scripts/jobs/run-slave.sh"

REMOTE_ARGS="--partition $(printf %q "$PARTITION") --deadline $DEADLINE_SEC"
[[ -n "$COMMAND" ]] && REMOTE_ARGS+=" --command $(printf %q "$COMMAND")"
[[ -n "$PROMPT" ]] && REMOTE_ARGS+=" --prompt $(printf %q "$PROMPT")"
[[ -n "$RUNTIME" ]] && REMOTE_ARGS+=" --runtime $(printf %q "$RUNTIME")"
[[ -n "$TASK_TITLE" ]] && REMOTE_ARGS+=" --task $(printf %q "$TASK_TITLE")"

out=$(ssh -o ConnectTimeout="$(read_master_default ssh_connect_timeout 15)" -o BatchMode=yes "$GATEWAY" \
  "timeout $SUBMIT_TIMEOUT bash '$REMOTE_SCRIPT' submit $REMOTE_ARGS" 2>&1) || {
  echo "ERROR: submit to $GATEWAY failed: $out" >&2
  exit 1
}

echo "$out"
job_id=$(echo "$out" | sed -n 's/^job_id=//p' | head -1)
if [[ -n "$job_id" ]]; then
  mkdir -p "$ROOT/var/agent-jobs"
  echo "$out" > "$ROOT/var/agent-jobs/${job_id}.submit.log"
fi
