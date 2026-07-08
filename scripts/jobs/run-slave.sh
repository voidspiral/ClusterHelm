#!/usr/bin/env bash
# Slave-side: submit / poll / background execute partition jobs.
set -euo pipefail

JOB_DIR="${AGENT_JOB_DIR:-/var/agent-jobs}"
NODE_SSH_TIMEOUT="${AGENT_NODE_SSH_TIMEOUT:-10}"

usage() {
  echo "Usage: $0 submit --partition EXPR (--command CMD | --prompt TASK) [--task TITLE] [--deadline SEC] [--runtime auto|cursor|opencode]" >&2
  echo "       $0 poll --job-id ID" >&2
  echo "  --command  script mode: deterministic per-node exec (built-in worker)" >&2
  echo "  --prompt   agent mode: launch the Slave agent CLI (cursor/opencode) with the task" >&2
  exit 1
}

slave_conf_get() {
  local key="$1" fallback="$2" conf
  conf="$(cd "$(dirname "$0")" && pwd)/slave.conf"
  if [[ -f "$conf" ]]; then
    local v
    v=$(sed -n "s/^${key}[[:space:]]\{1,\}//p" "$conf" | head -1)
    [[ -n "$v" ]] && { echo "$v"; return; }
  fi
  echo "$fallback"
}

# Resolve which agent CLI to use: cursor | opencode | none.
# Precedence: explicit arg > AGENT_RUNTIME env > slave.conf agent_runtime > auto.
resolve_runtime() {
  local pref="${1:-}"
  [[ -z "$pref" || "$pref" == "auto" ]] && pref="${AGENT_RUNTIME:-$(slave_conf_get agent_runtime auto)}"
  local cursor_bin opencode_bin
  cursor_bin="$(slave_conf_get agent_cursor_bin /root/.local/bin/agent)"
  opencode_bin="$(slave_conf_get agent_opencode_bin opencode)"
  case "$pref" in
    cursor) echo "cursor" ;;
    opencode) echo "opencode" ;;
    *)
      if command -v "$opencode_bin" >/dev/null 2>&1; then
        echo "opencode"
      elif [[ -x "$cursor_bin" ]] || command -v agent >/dev/null 2>&1; then
        echo "cursor"
      else
        echo "none"
      fi
      ;;
  esac
}

cmd_submit() {
  local partition="" command="" prompt="" runtime="" task_title="" deadline=1800
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --partition) partition="$2"; shift 2 ;;
      --command) command="$2"; shift 2 ;;
      --prompt) prompt="$2"; shift 2 ;;
      --runtime) runtime="$2"; shift 2 ;;
      --task) task_title="$2"; shift 2 ;;
      --deadline) deadline="$2"; shift 2 ;;
      *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$partition" && ( -n "$command" || -n "$prompt" ) ]] || usage

  mkdir -p "$JOB_DIR"
  local job_id="job-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local script_dir mode="script"
  [[ -n "$prompt" ]] && mode="agent"
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  local project_root
  project_root="$(cd "$script_dir/../.." && pwd)"
  local partition_input="$partition"
  partition=$(python3 "$script_dir/resolve-partition.py" "$partition" --validate)
  python3 - "$JOB_DIR" "$job_id" "$partition_input" "$partition" "$command" "$deadline" "$task_title" "$mode" "$prompt" "$runtime" "$project_root" <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta
(job_dir, job_id, partition_name, partition_nodeset, command, deadline,
 task_title, mode, prompt, runtime, project_root) = sys.argv[1:12]
deadline = int(deadline)
now = datetime.now(timezone.utc)
deadline_at = (now + timedelta(seconds=deadline)).strftime("%Y-%m-%dT%H:%M:%SZ")
data = {
    "job_id": job_id,
    "task_title": task_title or None,
    "partition": partition_name,
    "partition_nodeset": partition_nodeset,
    "mode": mode,
    "command": command or None,
    "task_prompt": prompt or None,
    "runtime": runtime or None,
    "status": "queued",
    "phase": "queued",
    "progress": {"total": 0, "ok": 0, "fail": 0, "pending": 0},
    "nodes": {},
    "submitted_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "updated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "deadline_at": deadline_at,
    "summary": None,
    "failures": [],
    "excluded_hosts": [],
    "newly_excluded": [],
}
with open(f"{job_dir}/{job_id}.json", "w") as f:
    json.dump(data, f, indent=2)

if mode == "agent":
    # Full prompt handed to the Slave agent CLI (cursor `agent -p` / `opencode run`).
    # The report contract markers are parsed back by _agent_worker's finalizer.
    contract = f"""You are the slave-agent, the partition owner on this gateway.

## Job context
- job_id: {job_id}
- job_json: {job_dir}/{job_id}.json
- partition: {partition_name} (nodeset: {partition_nodeset})
- deadline_utc: {deadline_at}

## Task
{prompt}

## Execution rules
1. **FIRST — partition availability:** every node in the nodeset must be checked (ping → SSH) and persisted exclusions loaded before any user task. Record reachable / excluded / unreachable in the report. Never exec on unverified or excluded nodes. (Agent jobs: preflight runs automatically into job JSON before you start — read `reachable_hosts` and `nodes` first.)
2. Operate only on nodes inside the nodeset above.
3. For deterministic partition-wide commands, prefer the built-in worker:
   {project_root}/scripts/jobs/run-slave.sh submit --partition {partition_name} --command '<cmd>'
   then poll it with: {project_root}/scripts/jobs/run-slave.sh poll --job-id <nested_job_id>
   (nested jobs are allowed; incorporate their results into your report).
4. Respect persisted exclusions: {project_root}/scripts/jobs/node_exclude.py list --partition {partition_name}
5. You may update {job_dir}/{job_id}.json incrementally (progress, nodes), but the final report contract below is what Master consumes.

## Required final output (contract with Master — print at the very end, exactly this shape)
AGENT_STATUS: <done|partial|failed>
===PARTITION_REPORT_BEGIN===
# Partition report: {partition_name} ({partition_nodeset})
<consolidated markdown: reachable/excluded/unreachable, per-node results>
===PARTITION_REPORT_END==="""
    with open(f"{job_dir}/{job_id}.prompt", "w") as f:
        f.write(contract)
print(job_id)
PY

  if [[ "$mode" == "agent" ]]; then
    nohup "$0" _agent_worker --job-id "$job_id" > "$JOB_DIR/${job_id}.worker.log" 2>&1 &
  else
    nohup "$0" _worker --job-id "$job_id" > "$JOB_DIR/${job_id}.worker.log" 2>&1 &
  fi
  echo "job_id=$job_id"
}

cmd_poll() {
  local job_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job-id) job_id="$2"; shift 2 ;;
      *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$job_id" ]] || usage
  local f="$JOB_DIR/${job_id}.json"
  [[ -f "$f" ]] || { echo "{\"error\":\"job not found\",\"job_id\":\"$job_id\"}"; exit 1; }
  cat "$f"
}

cmd_worker() {
  local job_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job-id) job_id="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$job_id" ]] || exit 1

  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  python3 - "$JOB_DIR" "$job_id" "$NODE_SSH_TIMEOUT" "$script_dir" <<'PY'
import json, re, socket, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

job_dir, job_id, ssh_timeout, script_dir = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
sys.path.insert(0, script_dir)
from node_exclude import NodeExclusionStore
path = f"{job_dir}/{job_id}.json"
_local = socket.gethostname().split(".")[0].lower()

def save(data):
    data["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

def is_local(host):
    h = host.split(".")[0].lower()
    return h in (_local, "localhost", "127.0.0.1")

def local_run(cmd=None, check_only=False, run_timeout=None):
    try:
        if check_only:
            return 0, ""
        tout = run_timeout if run_timeout is not None else ssh_timeout
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=tout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "local timeout"

def ssh_run(host, cmd=None, check_only=False, run_timeout=None):
    if is_local(host):
        return local_run(cmd, check_only, run_timeout)
    base = [
        "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new", host,
    ]
    if check_only:
        base.append("true")
    else:
        base.append(cmd)
    try:
        tout = run_timeout if run_timeout is not None else ssh_timeout
        r = subprocess.run(base, capture_output=True, text=True, timeout=tout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "ssh timeout"

def ping_host(host):
    if is_local(host):
        return 0, ""
    try:
        r = subprocess.run(
            ["ping", "-c", "1", "-W", "3", host],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode == 0:
            return 0, ""
        return 1, (r.stderr or r.stdout or "ping failed").strip()[:200]
    except subprocess.TimeoutExpired:
        return 124, "ping timeout"

def preflight_host(host):
    """Ping then SSH. Returns (ok, ping_ok, ssh_ok, error)."""
    if is_local(host):
        return True, True, True, ""
    prc, pout = ping_host(host)
    if prc != 0:
        return False, False, False, f"ping: {pout or 'fail'}"
    src, sout = ssh_run(host, check_only=True)
    if src != 0:
        return False, True, False, f"ssh: {sout.strip()[:200] or 'fail'}"
    return True, True, True, ""

def expand(expr):
    m = re.match(r"^([a-zA-Z]+)\[(.+)\]$", expr)
    if not m:
        return [expr]
    prefix, inner = m.group(1), m.group(2)
    out = []
    for part in inner.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(f"{prefix}{i}" for i in range(int(a), int(b) + 1))
        else:
            out.append(f"{prefix}{part}")
    return out

def is_mpi_job(cmd):
    return bool(cmd and ("fullcore" in cmd or "mpirun" in cmd))

def cleanup_mpi_hosts(hosts):
    script = Path(script_dir).parent / "mpi" / "cleanup-mpi.sh"
    if not script.is_file() or not hosts:
        return
    try:
        subprocess.run(
            ["bash", str(script), *hosts],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception:
        pass

with open(path) as f:
    data = json.load(f)

partition_name = data.get("partition") or data.get("partition_nodeset", "")
store = NodeExclusionStore(job_dir)
hosts = expand(data["partition_nodeset"])
data["progress"] = {"total": len(hosts), "ok": 0, "fail": 0, "pending": len(hosts), "excluded": 0}
data["reachable_hosts"] = []
data["excluded_hosts"] = []
data["newly_excluded"] = []
save(data)

# Skip persistently excluded nodes (preflight fail or frequent exec errors)
excluded_skip = 0
for host in hosts:
    excluded, entry = store.is_excluded(partition_name, host)
    if not excluded:
        continue
    excluded_skip += 1
    data["excluded_hosts"].append(host)
    data["nodes"][host] = {
        "state": "excluded",
        "phase": "skipped",
        "excluded": True,
        "exclude_reason": entry.get("reason"),
        "excluded_since": entry.get("excluded_since"),
        "last_fail_at": entry.get("last_fail_at"),
    }
    data["progress"]["excluded"] = excluded_skip
    save(data)

# Preflight: ping + SSH before every command (non-excluded only)
data["status"] = "preflight"
data["phase"] = "preflight"
ok = fail = 0
reachable = []
for host in hosts:
    if data["nodes"].get(host, {}).get("state") == "excluded":
        continue
    reachable_ok, ping_ok, ssh_ok, err = preflight_host(host)
    node = {
        "ping": "ok" if ping_ok else "fail",
        "ssh": "ok" if (ssh_ok or is_local(host)) else "fail",
    }
    if reachable_ok:
        node["state"] = "ok"
        node["phase"] = "preflight"
        reachable.append(host)
        ok += 1
    else:
        node["state"] = "fail"
        node["phase"] = "preflight"
        node["error"] = err
        data["failures"].append({"node": host, "phase": "preflight", "error": err})
        fail += 1
        store.record_preflight_failure(partition_name, host, err)
        ex_entry = store.get_entry(partition_name, host)
        node["excluded"] = True
        node["exclude_reason"] = ex_entry.get("reason") if ex_entry else err
        if host not in data["newly_excluded"]:
            data["newly_excluded"].append(host)
    data["nodes"][host] = node
    data["reachable_hosts"] = reachable
    data["progress"] = {
        "total": len(hosts),
        "ok": ok,
        "fail": fail,
        "pending": len(hosts) - ok - fail - excluded_skip,
        "excluded": excluded_skip + len(data["newly_excluded"]),
    }
    save(data)

# Execute
data["status"] = "running"
data["phase"] = "exec"
exec_ok = exec_fail = 0
deadline_at = datetime.fromisoformat(data["deadline_at"].replace("Z", "+00:00"))
exec_timeout = max(120, int((deadline_at - datetime.now(timezone.utc)).total_seconds()))
save(data)
for host in hosts:
    nstate = data["nodes"].get(host, {}).get("state")
    if nstate in ("fail", "excluded"):
        continue
    rc, out = ssh_run(host, cmd=data["command"], run_timeout=exec_timeout)
    if rc == 0:
        store.record_success(partition_name, host)
        data["nodes"][host] = {"state": "ok", "phase": "exec", "exit_code": 0, "stdout": out.strip()[:8000]}
        exec_ok += 1
    else:
        err = f"exit {rc}: {(out.strip()[:180] or 'no output')}"
        if is_mpi_job(data.get("command")):
            cleanup_mpi_hosts(data.get("reachable_hosts", []))
        ex_entry = store.record_exec_failure(partition_name, host, err)
        node = {
            "state": "fail",
            "phase": "exec",
            "exit_code": rc,
            "stderr": out.strip()[:8000],
        }
        if ex_entry:
            node["excluded"] = True
            node["exclude_reason"] = ex_entry.get("reason")
            node["excluded_since"] = ex_entry.get("excluded_since")
            if host not in data["newly_excluded"]:
                data["newly_excluded"].append(host)
        data["nodes"][host] = node
        data["failures"].append({"node": host, "phase": "exec", "error": err})
        exec_fail += 1
    excluded_total = len(data.get("excluded_hosts", [])) + len(data.get("newly_excluded", []))
    data["progress"] = {
        "total": len(hosts),
        "ok": exec_ok,
        "fail": exec_fail + fail,
        "pending": len(hosts) - exec_ok - exec_fail - fail - excluded_total,
        "excluded": excluded_total,
    }
    save(data)

total = len(hosts)
if exec_fail + fail == 0:
    status = "done"
elif exec_ok > 0:
    status = "partial"
else:
    status = "failed"

data["status"] = status
data["phase"] = "done"
data["summary"] = f"{exec_ok}/{total} ok, {exec_fail + fail} failed"

# Centralized partition report (Slave → Master presents this as-is)
persist_excluded = list(data.get("excluded_hosts", []))
newly_excluded = list(data.get("newly_excluded", []))
all_excluded = sorted(set(persist_excluded + newly_excluded))
unreachable = [
    h for h in hosts
    if h not in data.get("reachable_hosts", [])
    and data["nodes"].get(h, {}).get("state") != "excluded"
]
exec_ok_hosts = [h for h in hosts if data["nodes"].get(h, {}).get("phase") == "exec" and data["nodes"][h].get("state") == "ok"]
exec_fail_hosts = [
    h for h in hosts
    if data["nodes"].get(h, {}).get("phase") == "exec"
    and data["nodes"][h].get("state") == "fail"
    and not data["nodes"][h].get("excluded")
]
exec_excluded_hosts = [
    h for h in hosts
    if data["nodes"].get(h, {}).get("excluded")
]

lines = [
    f"# Partition report: {data.get('partition', '?')} ({data.get('partition_nodeset', '?')})",
]
if data.get("task_title"):
    lines.append(f"- Task: {data['task_title']}")
lines.extend([
    "",
    f"- Gateway: {socket.gethostname().split('.')[0]}",
    f"- Status: {status}",
    f"- Reachable: {len(data.get('reachable_hosts', []))}/{total} — {', '.join(data.get('reachable_hosts', [])) or 'none'}",
    f"- Exec ok: {len(exec_ok_hosts)} — {', '.join(exec_ok_hosts) or 'none'}",
])
if all_excluded:
    lines.append(f"- Excluded (skipped): {len(all_excluded)}/{total} — {', '.join(all_excluded)}")
if unreachable:
    lines.append(f"- Unreachable: {', '.join(unreachable)}")
if exec_fail_hosts:
    lines.append(f"- Exec failed: {', '.join(exec_fail_hosts)}")
if newly_excluded:
    lines.append(f"- Newly excluded this job: {', '.join(newly_excluded)}")
lines.append("")
lines.append("## Per-node")
for h in hosts:
    n = data["nodes"].get(h, {})
    if n.get("state") == "excluded" or (n.get("excluded") and n.get("phase") == "skipped"):
        lines.append(
            f"- **{h}** excluded: {(n.get('exclude_reason') or '?')[:120]}"
        )
    elif n.get("state") == "ok" and n.get("phase") == "exec":
        snippet = (n.get("stdout") or "").split("\n")[0][:120]
        lines.append(f"- **{h}** ok: {snippet}")
    elif n.get("state") == "fail":
        tag = "excluded" if n.get("excluded") else n.get("phase", "fail")
        lines.append(f"- **{h}** fail ({tag}): {(n.get('error') or n.get('stderr') or n.get('exclude_reason') or '?')[:120]}")

data["partition_report"] = {
    "task_title": data.get("task_title"),
    "gateway": socket.gethostname().split(".")[0],
    "partition": data.get("partition"),
    "partition_nodeset": data.get("partition_nodeset"),
    "status": status,
    "reachable": data.get("reachable_hosts", []),
    "excluded": all_excluded,
    "excluded_persisted": persist_excluded,
    "excluded_new": newly_excluded,
    "unreachable": unreachable,
    "exec_ok": exec_ok_hosts,
    "exec_fail": exec_fail_hosts,
    "exec_excluded": exec_excluded_hosts,
    "summary_line": data["summary"],
    "markdown": "\n".join(lines),
}
save(data)
PY
}

cmd_agent_worker() {
  local job_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job-id) job_id="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$job_id" ]] || exit 1

  local script_dir project_root path prompt_file agent_log
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  project_root="$(cd "$script_dir/../.." && pwd)"
  path="$JOB_DIR/${job_id}.json"
  prompt_file="$JOB_DIR/${job_id}.prompt"
  agent_log="$JOB_DIR/${job_id}.agent.log"
  [[ -f "$path" && -f "$prompt_file" ]] || exit 1

  # Partition availability first (ping/SSH + exclusions) before launching Slave agent LLM.
  python3 "$script_dir/job_preflight.py" "$JOB_DIR" "$job_id" "$NODE_SSH_TIMEOUT"

  local requested_runtime runtime
  requested_runtime=$(python3 -c "import json; print(json.load(open('$path')).get('runtime') or '')")
  runtime=$(resolve_runtime "$requested_runtime")

  # Mark running before launching the CLI so Master polls see progress.
  python3 - "$path" "$runtime" <<'PY'
import json, sys
from datetime import datetime, timezone
path, runtime = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data["status"] = "running"
data["phase"] = "agent"
data["runtime"] = runtime
data["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY

  local timeout_sec
  timeout_sec=$(python3 - "$path" <<'PY'
import json, sys
from datetime import datetime, timezone
with open(sys.argv[1]) as f:
    data = json.load(f)
deadline = datetime.fromisoformat(data["deadline_at"].replace("Z", "+00:00"))
print(max(120, int((deadline - datetime.now(timezone.utc)).total_seconds())))
PY
)

  local prompt rc=0
  prompt="$(cat "$prompt_file")"
  local cursor_bin opencode_bin opencode_agent
  cursor_bin="$(slave_conf_get agent_cursor_bin /root/.local/bin/agent)"
  opencode_bin="$(slave_conf_get agent_opencode_bin opencode)"
  opencode_agent="$(slave_conf_get agent_opencode_agent slave-agent)"

  case "$runtime" in
    opencode)
      (cd "$project_root" && timeout "$timeout_sec" "$opencode_bin" run --agent "$opencode_agent" --auto "$prompt") \
        > "$agent_log" 2>&1 || rc=$?
      ;;
    cursor)
      export PATH="/root/.local/bin:$PATH"
      local cursor_cmd="$cursor_bin"
      [[ -x "$cursor_cmd" ]] || cursor_cmd="agent"
      (cd "$project_root" && timeout "$timeout_sec" "$cursor_cmd" -p "$prompt") \
        > "$agent_log" 2>&1 || rc=$?
      ;;
    *)
      echo "ERROR: no agent CLI available (agent_runtime=$requested_runtime resolved=$runtime)" > "$agent_log"
      rc=127
      ;;
  esac

  # Finalize: honor JSON if the agent already wrote a terminal partition_report;
  # otherwise parse the report contract from the CLI output.
  python3 - "$path" "$agent_log" "$rc" "$runtime" <<'PY'
import json, re, socket, sys
from datetime import datetime, timezone
path, log_path, rc, runtime = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
with open(path) as f:
    data = json.load(f)
if data.get("status") in ("done", "partial", "failed") and data.get("partition_report"):
    sys.exit(0)
try:
    log = open(log_path, errors="replace").read()
except OSError:
    log = ""

md_match = re.search(
    r"===PARTITION_REPORT_BEGIN===\s*\n(.*?)\n?\s*===PARTITION_REPORT_END===",
    log, re.DOTALL)
status_match = None
for m in re.finditer(r"AGENT_STATUS:\s*(done|partial|failed)", log):
    status_match = m.group(1)

if md_match:
    markdown = md_match.group(1).strip()
    status = status_match or ("done" if rc == 0 else "failed")
else:
    status = "failed"
    reason = "deadline exceeded (timeout)" if rc == 124 else f"exit {rc}, report contract missing"
    tail = log.strip()[-2000:] or "no output"
    markdown = (
        f"# Agent job failed: {data.get('partition', '?')}\n\n"
        f"- Runtime: {runtime}\n- Reason: {reason}\n\n"
        f"## Agent output (tail)\n```\n{tail}\n```"
    )

summary = f"agent {status} (runtime={runtime}, exit={rc})"
data["status"] = status
data["phase"] = "done"
data["summary"] = summary
data["partition_report"] = {
    "task_title": data.get("task_title"),
    "gateway": socket.gethostname().split(".")[0],
    "partition": data.get("partition"),
    "partition_nodeset": data.get("partition_nodeset"),
    "status": status,
    "mode": "agent",
    "runtime": runtime,
    "summary_line": summary,
    "markdown": markdown,
}
data["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
}

main="${1:-}"
shift || true
case "$main" in
  submit) cmd_submit "$@" ;;
  poll) cmd_poll "$@" ;;
  _worker) cmd_worker "$@" ;;
  _agent_worker) cmd_agent_worker "$@" ;;
  *) usage ;;
esac
