#!/usr/bin/env bash
# Slave-side: submit / poll / background execute partition jobs.
set -euo pipefail

JOB_DIR="${AGENT_JOB_DIR:-/var/agent-jobs}"
NODE_SSH_TIMEOUT="${AGENT_NODE_SSH_TIMEOUT:-10}"

usage() {
  echo "Usage: $0 submit --partition EXPR --command CMD [--task TITLE] [--deadline SEC]" >&2
  echo "       $0 poll --job-id ID" >&2
  exit 1
}

cmd_submit() {
  local partition="" command="" task_title="" deadline=1800
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --partition) partition="$2"; shift 2 ;;
      --command) command="$2"; shift 2 ;;
      --task) task_title="$2"; shift 2 ;;
      --deadline) deadline="$2"; shift 2 ;;
      *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$partition" && -n "$command" ]] || usage

  mkdir -p "$JOB_DIR"
  local job_id="job-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  local partition_input="$partition"
  partition=$(python3 "$script_dir/resolve-partition.py" "$partition" --validate)
  python3 - "$JOB_DIR" "$job_id" "$partition_input" "$partition" "$command" "$deadline" "$task_title" <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta
job_dir, job_id, partition_name, partition_nodeset, command, deadline, task_title = sys.argv[1:8]
deadline = int(deadline)
now = datetime.now(timezone.utc)
data = {
    "job_id": job_id,
    "task_title": task_title or None,
    "partition": partition_name,
    "partition_nodeset": partition_nodeset,
    "command": command,
    "status": "queued",
    "phase": "queued",
    "progress": {"total": 0, "ok": 0, "fail": 0, "pending": 0},
    "nodes": {},
    "submitted_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "updated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "deadline_at": (now + timedelta(seconds=deadline)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "summary": None,
    "failures": [],
    "excluded_hosts": [],
    "newly_excluded": [],
}
with open(f"{job_dir}/{job_id}.json", "w") as f:
    json.dump(data, f, indent=2)
print(job_id)
PY

  nohup "$0" _worker --job-id "$job_id" > "$JOB_DIR/${job_id}.worker.log" 2>&1 &
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

def local_run(cmd=None, check_only=False):
    try:
        if check_only:
            return 0, ""
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=ssh_timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "local timeout"

def ssh_run(host, cmd=None, check_only=False):
    if is_local(host):
        return local_run(cmd, check_only)
    base = [
        "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new", host,
    ]
    if check_only:
        base.append("true")
    else:
        base.append(cmd)
    try:
        r = subprocess.run(base, capture_output=True, text=True, timeout=ssh_timeout)
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
for host in hosts:
    nstate = data["nodes"].get(host, {}).get("state")
    if nstate in ("fail", "excluded"):
        continue
    rc, out = ssh_run(host, cmd=data["command"])
    if rc == 0:
        store.record_success(partition_name, host)
        data["nodes"][host] = {"state": "ok", "phase": "exec", "exit_code": 0, "stdout": out.strip()[:500]}
        exec_ok += 1
    else:
        err = f"exit {rc}: {(out.strip()[:180] or 'no output')}"
        ex_entry = store.record_exec_failure(partition_name, host, err)
        node = {
            "state": "fail",
            "phase": "exec",
            "exit_code": rc,
            "stderr": out.strip()[:500],
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

main="${1:-}"
shift || true
case "$main" in
  submit) cmd_submit "$@" ;;
  poll) cmd_poll "$@" ;;
  _worker) cmd_worker "$@" ;;
  *) usage ;;
esac
