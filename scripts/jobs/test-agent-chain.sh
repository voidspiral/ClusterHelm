#!/usr/bin/env bash
# End-to-end tests: Master and Slave cn1 via OpenCode.
# Baseline submit/poll always runs; agent LLM tests run unless SKIP_AGENT_TESTS=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY="${GATEWAY:-cn1}"
REMOTE_PROJECT="/home/smt/agents"
LOG_DIR="${LOG_DIR:-$ROOT/var/agent-jobs/test-chain}"
mkdir -p "$LOG_DIR"

PASS=0
FAIL=0
SKIP=0

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL: $*" >&2; }
skip() { SKIP=$((SKIP + 1)); log "SKIP: $*"; }

run_section() {
  log "======== $1 ========"
}

# Poll job until terminal or max rounds
poll_until_terminal() {
  local job_id="$1" max_rounds="${2:-24}" interval="${3:-5}"
  local round=0 status=""
  while [[ $round -lt $max_rounds ]]; do
    "$JOBS_DIR/poll.sh" --job-id "$job_id" --gateway "$GATEWAY" > "$LOG_DIR/${job_id}.poll.json" 2>"$LOG_DIR/${job_id}.poll.stderr" || true
    status=$(python3 -c "import json; d=json.load(open('$LOG_DIR/${job_id}.poll.json')); print(d.get('status',''))" 2>/dev/null || echo "")
    case "$status" in
      done|partial|failed) echo "$status"; return 0 ;;
    esac
    round=$((round + 1))
    sleep "$interval"
  done
  echo "$status"
  return 1
}

assert_partition_report() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
status = d.get("status", "")
if status not in ("done", "partial", "failed"):
    print(f"status not terminal: {status}")
    sys.exit(1)
pr = d.get("partition_report") or {}
md = pr.get("markdown", "")
if not md.strip():
    print("partition_report.markdown empty")
    sys.exit(1)
if d.get("partition") != "test":
    print(f"expected partition=test, got {d.get('partition')}")
    sys.exit(1)
print(f"ok status={status} summary={pr.get('summary_line','')[:80]}")
PY
}

assert_memory_json() {
  local text_file="$1"
  python3 - "$text_file" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
# find JSON object with mem_total_mb
m = re.search(r'\{[^{}]*"mem_total_mb"[^{}]*\}', text, re.DOTALL)
if not m:
    # try nested / multiline
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{") and "mem_total_mb" in line:
            try:
                d = json.loads(line)
                if "mem_total_mb" in d:
                    print(f"ok host={d.get('host')} mem_used_pct={d.get('mem_used_pct')}")
                    sys.exit(0)
            except json.JSONDecodeError:
                pass
    print("no mem_total_mb JSON in output")
    sys.exit(1)
d = json.loads(m.group(0))
if "mem_total_mb" not in d:
    print("missing mem_total_mb")
    sys.exit(1)
print(f"ok host={d.get('host')} mem_used_pct={d.get('mem_used_pct')}")
PY
}

# --- 3.1 Preflight ---
run_section "Preflight (Master)"
if opencode agent list 2>/dev/null | grep -q 'master-agent (primary)'; then
  pass "Master opencode agent: master-agent"
else
  fail "Master opencode agent master-agent not found"
fi
[[ -f "$ROOT/.opencode/agents/master-agent.md" ]] && pass "master-agent.md exists" || fail "missing master-agent.md"

run_section "Preflight (cn1)"
ssh -o ConnectTimeout=15 "$GATEWAY" "
  opencode agent list | grep -q 'slave-agent (primary)'
  test -f $REMOTE_PROJECT/.opencode/skills/memory-monitor/SKILL.md
" && pass "cn1 preflight (slave-agent, skills)" || fail "cn1 preflight"

# --- Baseline: submit/poll without LLM ---
run_section "Baseline submit/poll (Master scripts → cn1 run-slave)"
BASELINE_OUT=$("$JOBS_DIR/submit.sh" --partition test --command 'hostname -s' --task agent-chain-baseline 2>&1)
echo "$BASELINE_OUT" > "$LOG_DIR/baseline.submit.log"
JOB_ID=$(echo "$BASELINE_OUT" | sed -n 's/^job_id=//p' | head -1)
if [[ -z "$JOB_ID" ]]; then
  fail "baseline submit: no job_id"
else
  pass "baseline submit job_id=$JOB_ID"
  FINAL_STATUS=$(poll_until_terminal "$JOB_ID" 30 5 || true)
  if [[ "$FINAL_STATUS" =~ ^(done|partial|failed)$ ]]; then
    if assert_partition_report "$LOG_DIR/${JOB_ID}.poll.json" > "$LOG_DIR/baseline.assert.log" 2>&1; then
      pass "baseline partition_report ($FINAL_STATUS)"
      cp "$LOG_DIR/${JOB_ID}.poll.json" "$ROOT/var/agent-jobs/${JOB_ID}.last.json" 2>/dev/null || true
    else
      fail "baseline partition_report assertion: $(cat "$LOG_DIR/baseline.assert.log")"
    fi
  else
    fail "baseline poll timeout status=$FINAL_STATUS"
  fi
fi

if [[ "${SKIP_AGENT_TESTS:-0}" == "1" ]]; then
  skip "Agent LLM tests (SKIP_AGENT_TESTS=1)"
  run_section "Summary"
  log "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
  [[ "$FAIL" -eq 0 ]]
  exit 0
fi

# --- Agent-to-agent: Master scripts → gateway launches Slave agent CLI ---
run_section "Agent-mode submit (submit.sh --prompt → Slave agent CLI on cn1)"
A2A_TASK='对分区每个可达节点执行 hostname -s，汇总为 partition report。'
A2A_OUT=$("$JOBS_DIR/submit.sh" --partition test --prompt "$A2A_TASK" --task agent-mode-baseline --deadline 900 2>&1)
echo "$A2A_OUT" > "$LOG_DIR/agent-mode.submit.log"
A2A_JOB=$(echo "$A2A_OUT" | sed -n 's/^job_id=//p' | head -1)
if [[ -z "$A2A_JOB" ]]; then
  fail "agent-mode submit: no job_id (see $LOG_DIR/agent-mode.submit.log)"
else
  pass "agent-mode submit job_id=$A2A_JOB"
  A2A_STATUS=$(poll_until_terminal "$A2A_JOB" 60 10 || true)
  if [[ "$A2A_STATUS" =~ ^(done|partial|failed)$ ]]; then
    if assert_partition_report "$LOG_DIR/${A2A_JOB}.poll.json" > "$LOG_DIR/agent-mode.assert.log" 2>&1; then
      A2A_RUNTIME=$(python3 -c "import json; d=json.load(open('$LOG_DIR/${A2A_JOB}.poll.json')); print(d.get('runtime','?'))" 2>/dev/null || echo "?")
      if [[ "$A2A_STATUS" == "failed" ]]; then
        fail "agent-mode job failed (runtime=$A2A_RUNTIME, see gateway ${A2A_JOB}.agent.log)"
      else
        pass "agent-mode partition_report ($A2A_STATUS, runtime=$A2A_RUNTIME)"
      fi
    else
      fail "agent-mode partition_report assertion: $(cat "$LOG_DIR/agent-mode.assert.log")"
    fi
  else
    fail "agent-mode poll timeout status=$A2A_STATUS"
  fi
fi

# --- Agent-to-agent: Master submit --prompt → Slave agent CLI on gateway ---
run_section "Agent-mode submit (Master → Slave agent CLI on cn1)"
A2A_OUT=$("$JOBS_DIR/submit.sh" --partition test \
  --prompt '对分区每个节点执行 hostname -s，汇总可达性与每节点结果，按契约输出 partition report' \
  --task a2a-hostname 2>&1)
echo "$A2A_OUT" > "$LOG_DIR/a2a.submit.log"
A2A_JOB=$(echo "$A2A_OUT" | sed -n 's/^job_id=//p' | head -1)
if [[ -z "$A2A_JOB" ]]; then
  fail "agent-mode submit: no job_id (see $LOG_DIR/a2a.submit.log)"
else
  pass "agent-mode submit job_id=$A2A_JOB"
  A2A_STATUS=$(poll_until_terminal "$A2A_JOB" 60 10 || true)
  if [[ "$A2A_STATUS" =~ ^(done|partial)$ ]]; then
    if assert_partition_report "$LOG_DIR/${A2A_JOB}.poll.json" > "$LOG_DIR/a2a.assert.log" 2>&1; then
      pass "agent-mode partition_report ($A2A_STATUS)"
    else
      fail "agent-mode partition_report assertion: $(cat "$LOG_DIR/a2a.assert.log")"
    fi
  else
    fail "agent-mode job status=$A2A_STATUS (gateway log: /home/smt/agents/var/agent-jobs/${A2A_JOB}.agent.log)"
  fi
fi

MASTER_PROMPT='向 test 分区执行 hostname -s。必须使用 ./scripts/jobs/submit.sh --partition test 提交，然后用 ./scripts/jobs/poll-wait.sh 阻塞等待完成，最后呈现 partition_report.markdown。禁止直接 ssh 到 cn1-cn10 执行命令。'

# --- 3.2 Master OpenCode ---
run_section "Master OpenCode → test partition"
OC_LOG="$LOG_DIR/master-opencode.log"
if (cd "$ROOT" && opencode run --agent master-agent --auto "$MASTER_PROMPT" > "$OC_LOG" 2>&1); then
  LATEST=$(ls -t "$ROOT"/var/agent-jobs/*.last.json 2>/dev/null | head -1 || true)
  if [[ -n "$LATEST" ]] && assert_partition_report "$LATEST" >> "$OC_LOG" 2>&1; then
    pass "Master OpenCode partition_report ($(basename "$LATEST"))"
  else
    # Agent may not have polled to terminal — try poll latest job from submit log
    LATEST_JOB=$(grep -h '^job_id=' "$ROOT"/var/agent-jobs/*.submit.log 2>/dev/null | tail -1 | sed 's/job_id=//')
    if [[ -n "$LATEST_JOB" ]]; then
      poll_until_terminal "$LATEST_JOB" 20 5 > /dev/null || true
      if [[ -f "$LOG_DIR/${LATEST_JOB}.poll.json" ]] && assert_partition_report "$LOG_DIR/${LATEST_JOB}.poll.json" >> "$OC_LOG" 2>&1; then
        pass "Master OpenCode (supplemental poll) job=$LATEST_JOB"
      else
        fail "Master OpenCode: no valid partition_report (see $OC_LOG)"
      fi
    else
      fail "Master OpenCode: no job_id found (see $OC_LOG)"
    fi
  fi
else
  fail "Master OpenCode run failed (see $OC_LOG)"
fi

SLAVE_MEM_PROMPT='检查本机内存。加载 memory-monitor skill，运行 /home/smt/agents/scripts/monitor/mem-api.sh local，输出 JSON 并简要说明 mem_used_pct。禁止 ssh 到其他节点跑 free。'

# --- 3.3 Slave OpenCode + skill ---
run_section "Slave OpenCode + memory-monitor skill (cn1)"
SOC_LOG="$LOG_DIR/slave-opencode.log"
if ssh -o ConnectTimeout=15 "$GATEWAY" "cd $REMOTE_PROJECT && opencode run --agent slave-agent --auto $(printf %q "$SLAVE_MEM_PROMPT")" > "$SOC_LOG" 2>&1; then
  if assert_memory_json "$SOC_LOG" >> "$SOC_LOG" 2>&1; then
    pass "Slave OpenCode mem-api local JSON"
  else
    fail "Slave OpenCode: no memory JSON (see $SOC_LOG)"
  fi
else
  fail "Slave OpenCode run failed (see $SOC_LOG)"
fi

# --- Optional: Slave OpenCode run-slave hostname ---
run_section "Slave OpenCode run-slave hostname (cn1)"
SRH_LOG="$LOG_DIR/slave-opencode-hostname.log"
SRH_PROMPT='对 test 分区执行 hostname -s。使用 /home/smt/agents/scripts/jobs/run-slave.sh submit --partition test 提交，poll 至终态，呈现 partition_report。'
if ssh -o ConnectTimeout=15 "$GATEWAY" "cd $REMOTE_PROJECT && opencode run --agent slave-agent --auto $(printf %q "$SRH_PROMPT")" > "$SRH_LOG" 2>&1; then
  if grep -qE 'partition_report|Partition report|hostname' "$SRH_LOG"; then
    pass "Slave OpenCode run-slave hostname (output contains report markers)"
  else
    fail "Slave OpenCode hostname: unexpected output (see $SRH_LOG)"
  fi
else
  fail "Slave OpenCode hostname run failed (see $SRH_LOG)"
fi

run_section "Summary"
log "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
log "Logs: $LOG_DIR"
[[ "$FAIL" -eq 0 ]]
