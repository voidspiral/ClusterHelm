#!/usr/bin/env bash
# Master-side: submit async job to a slave gateway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Monorepo: var/ at repo root; deployed flat: var/ next to scripts/
if [[ -d "$MASTER_ROOT/../slave" ]]; then
  ROOT="$(cd "$MASTER_ROOT/.." && pwd)"
else
  ROOT="$MASTER_ROOT"
fi
CONFIG="$MASTER_ROOT/config/master.conf"
# shellcheck source=ssh-transport.sh
CLUSTERHELM_MASTER_CONF="$CONFIG"
source "$SCRIPT_DIR/ssh-transport.sh"
GATEWAY=""
PARTITION=""
COMMAND=""
PROMPT=""
RUNTIME=""
TASK_TITLE=""
DEADLINE_SEC=""
FOLLOW=1
EXEC_SCOPE=""

read_master_default() {
  local key="$1" fallback="$2"
  if [[ -f "$CONFIG" ]]; then
    local v
    v=$(grep -E "^${key}[[:space:]]" "$CONFIG" | awk '{print $2}' | head -1)
    [[ -n "$v" ]] && echo "$v" && return
  fi
  echo "$fallback"
}

usage() {
  echo "Usage: $0 --partition EXPR (--command CMD | --prompt TASK) [--task TITLE] [--gateway HOST] [--deadline SEC] [--runtime auto|opencode] [--follow|--no-follow] [--exec-scope auto|gateway|nodeset]" >&2
  echo "  Job = one decomposed task delegated to a slave (not limited to MPI)." >&2
  echo "  --command  script mode: slave runs the command verbatim on each node" >&2
  echo "  --prompt   agent mode: gateway launches the Slave agent CLI with the task (agent-to-agent)" >&2
  echo "  --runtime  agent CLI on gateway; default from gateway slave.conf (auto)" >&2
  echo "  --follow   default: submit then wait on the same SSH connection" >&2
  echo "  --no-follow  async submit only (use for parallel jobs; then poll-wait)" >&2
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
    --follow) FOLLOW=1; shift ;;
    --no-follow) FOLLOW=0; shift ;;
    --exec-scope) EXEC_SCOPE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$PARTITION" && ( -n "$COMMAND" || -n "$PROMPT" ) ]] || usage

DEADLINE_SEC="${DEADLINE_SEC:-$(read_master_default default_deadline 1800)}"
GATEWAY="${GATEWAY:-$(python3 "$SCRIPT_DIR/list-slaves.py" --partition "$PARTITION" 2>/dev/null || read_master_default default_gateway cn1)}"
SUBMIT_TIMEOUT="$(read_master_default submit_timeout 30)"
WAIT_SLACK="$(read_master_default wait_slack 30)"
REMOTE_PROJECT="$(read_master_default remote_project "")"
[[ -n "$REMOTE_PROJECT" ]] || { echo "ERROR: set remote_project in $CONFIG" >&2; exit 1; }
REMOTE_RUN_SLAVE="$(read_master_default remote_run_slave scripts/run-slave.sh)"
REMOTE_SCRIPT="${REMOTE_PROJECT}/${REMOTE_RUN_SLAVE}"
VAR_JOBS="${CLUSTERHELM_VAR_ROOT:-$ROOT/var}/agent-jobs"
mkdir -p "$VAR_JOBS"

REMOTE_ARGS="--partition $(printf %q "$PARTITION") --deadline $DEADLINE_SEC"
[[ -n "$COMMAND" ]] && REMOTE_ARGS+=" --command $(printf %q "$COMMAND")"
[[ -n "$PROMPT" ]] && REMOTE_ARGS+=" --prompt $(printf %q "$PROMPT")"
[[ -n "$RUNTIME" ]] && REMOTE_ARGS+=" --runtime $(printf %q "$RUNTIME")"
[[ -n "$TASK_TITLE" ]] && REMOTE_ARGS+=" --task $(printf %q "$TASK_TITLE")"
[[ -n "$EXEC_SCOPE" ]] && REMOTE_ARGS+=" --exec-scope $(printf %q "$EXEC_SCOPE")"

if [[ "$FOLLOW" -eq 1 ]]; then
  WAIT_TIMEOUT=$((DEADLINE_SEC + WAIT_SLACK))
  REMOTE=$(cat <<EOF
set -euo pipefail
out=\$(bash $(printf %q "$REMOTE_SCRIPT") submit $REMOTE_ARGS)
printf '%s\n' "\$out"
job_id=\$(printf '%s\n' "\$out" | sed -n 's/^job_id=//p' | head -1)
[ -n "\$job_id" ]
echo CLUSTERHELM_JOB_JSON
bash $(printf %q "$REMOTE_SCRIPT") wait --job-id "\$job_id" --timeout $WAIT_TIMEOUT
EOF
)
  out=$(clusterhelm_ssh "$GATEWAY" "$REMOTE") || {
    echo "ERROR: submit --follow to $GATEWAY failed: $out" >&2
    exit 1
  }
else
  out=$(clusterhelm_ssh "$GATEWAY" \
    "timeout $SUBMIT_TIMEOUT bash $(printf %q "$REMOTE_SCRIPT") submit $REMOTE_ARGS") || {
    echo "ERROR: submit to $GATEWAY failed: $out" >&2
    exit 1
  }
fi

job_id=$(printf '%s\n' "$out" | sed -n 's/^job_id=//p' | head -1)
if [[ -n "$job_id" ]]; then
  printf '%s\n' "$out" | sed '/^CLUSTERHELM_JOB_JSON$/,$d' > "$VAR_JOBS/${job_id}.submit.log"
  echo "job_id=$job_id"
fi

if [[ "$FOLLOW" -eq 1 ]]; then
  json=$(printf '%s\n' "$out" | awk 'BEGIN{p=0} $0=="CLUSTERHELM_JOB_JSON"{p=1; next} p{print}')
  if [[ -n "$job_id" && -n "$json" ]]; then
    printf '%s\n' "$json" > "$VAR_JOBS/${job_id}.last.json"
  fi
  echo "$json"
  status=$(printf '%s\n' "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "?")
  report=$(printf '%s\n' "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('partition_report',{}).get('markdown',''))" 2>/dev/null || true)
  echo "status=$status" >&2
  if [[ -n "$report" ]]; then
    echo "--- partition_report ---" >&2
    echo "$report" >&2
  fi
  case "$status" in
    done|partial) exit 0 ;;
    *) exit 1 ;;
  esac
fi
