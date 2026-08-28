#!/usr/bin/env python3
"""Job completion signal, agent finalize, and remaining-deadline helpers."""
from __future__ import annotations

import json
import os
import re
import signal
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))
import incident_io  # noqa: E402

TERMINAL = ("done", "partial", "failed")
CONTRACT_BEGIN = "===PARTITION_REPORT_BEGIN==="
CONTRACT_END = "===PARTITION_REPORT_END==="


def master_wait_timeout(default_deadline: int, wait_slack: int) -> int:
    return int(default_deadline) + int(wait_slack)


def remaining_seconds(deadline_at, now=None, floor: int = 1) -> int:
    """Seconds until deadline. Does not inflate short deadlines to 120s."""
    if now is None:
        now = datetime.now(timezone.utc)
    if isinstance(deadline_at, str):
        deadline_at = datetime.fromisoformat(deadline_at.replace("Z", "+00:00"))
    remaining = int((deadline_at - now).total_seconds())
    return max(floor, remaining)


def remaining_from_job(job_json: str, floor: int = 1) -> int:
    with open(job_json) as f:
        data = json.load(f)
    return remaining_seconds(data["deadline_at"], floor=floor)


def write_done(job_dir, job_id: str, status: str) -> Path:
    path = Path(job_dir) / f"{job_id}.done"
    tmp = path.with_suffix(".done.tmp")
    tmp.write_text(f"{status}\n")
    tmp.replace(path)
    return path


def fail_signal_if_missing(job_dir, job_id: str, status: str = "failed") -> None:
    done = Path(job_dir) / f"{job_id}.done"
    if done.is_file():
        return
    job_path = Path(job_dir) / f"{job_id}.json"
    if job_path.is_file():
        try:
            data = json.loads(job_path.read_text())
            if data.get("status") in TERMINAL:
                write_done(job_dir, job_id, data["status"])
                return
            data["status"] = status
            data["phase"] = "done"
            data.setdefault("summary", "worker aborted before finalize")
            data["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            job_path.write_text(json.dumps(data, indent=2))
        except (OSError, json.JSONDecodeError):
            pass
    write_done(job_dir, job_id, status)


def parse_contract(log: str):
    md_match = re.search(
        rf"{re.escape(CONTRACT_BEGIN)}\s*\n(.*?)\n?\s*{re.escape(CONTRACT_END)}",
        log,
        re.DOTALL,
    )
    status_match = None
    for m in re.finditer(r"AGENT_STATUS:\s*(done|partial|failed)", log):
        status_match = m.group(1)
    if not md_match or not status_match:
        return None
    return status_match, md_match.group(1).strip()


def _read_log(log_path: str) -> str:
    try:
        return Path(log_path).read_text(errors="replace")
    except OSError:
        return ""


def apply_incident_sidecar(job_json: str) -> dict | None:
    """Merge `<job>.incident.json` into a running job. Does not finalize."""
    inc_path = incident_io.incident_path_for_job(job_json)
    incident = incident_io.load_incident(inc_path)
    if not incident:
        return None
    job_path = Path(job_json)
    with open(job_path) as f:
        data = json.load(f)
    if data.get("status") in TERMINAL:
        return incident
    incident_io.merge_incident_into_job(data, incident)
    with open(job_path, "w") as f:
        json.dump(data, f, indent=2)
    return incident


def finalize_agent_from_log(
    job_json: str,
    log_path: str,
    rc: int,
    runtime: str,
    *,
    fail_reason: str | None = None,
) -> dict:
    with open(job_json) as f:
        data = json.load(f)
    if data.get("status") in TERMINAL and data.get("partition_report"):
        if data.get("nodestatus_snapshot"):
            for key, value in data["nodestatus_snapshot"].items():
                data["partition_report"].setdefault(key, value)
            data["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            with open(job_json, "w") as f:
                json.dump(data, f, indent=2)
        return data

    log = _read_log(log_path)
    parsed = parse_contract(log)
    incident = incident_io.load_incident(incident_io.incident_path_for_job(job_json))
    incident_block = incident_io.incident_markdown(incident)
    if parsed:
        status, markdown = parsed
        if incident_block and "## Incident" not in markdown:
            markdown = f"{markdown.rstrip()}\n\n{incident_block}\n"
    else:
        md_match = re.search(
            rf"{re.escape(CONTRACT_BEGIN)}\s*\n(.*?)\n?\s*{re.escape(CONTRACT_END)}",
            log,
            re.DOTALL,
        )
        status_match = None
        for m in re.finditer(r"AGENT_STATUS:\s*(done|partial|failed)", log):
            status_match = m.group(1)
        if md_match:
            markdown = md_match.group(1).strip()
            status = status_match or ("done" if rc == 0 else "failed")
            if incident_block and "## Incident" not in markdown:
                markdown = f"{markdown.rstrip()}\n\n{incident_block}\n"
        else:
            status = "failed"
            reason = fail_reason or (
                "deadline exceeded (timeout)"
                if rc == 124
                else f"exit {rc}, report contract missing"
            )
            tail = log.strip()[-2000:] or "no output"
            extra = f"{incident_block}\n\n" if incident_block else ""
            markdown = (
                f"# Agent job failed: {data.get('partition', '?')}\n\n"
                f"- Runtime: {runtime}\n- Reason: {reason}\n\n"
                f"{extra}"
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
    if data.get("nodestatus_snapshot"):
        data["partition_report"].update(data["nodestatus_snapshot"])
    data["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(job_json, "w") as f:
        json.dump(data, f, indent=2)
    return data


def kill_process_group(pid: int, grace: float = 0.8) -> None:
    if pid <= 0:
        return
    own_pgid = os.getpgrp()
    try:
        pgid = os.getpgid(pid)
    except ProcessLookupError:
        return

    def _term():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        if pgid != own_pgid:
            try:
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError, OSError):
                pass

    def _kill():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        if pgid != own_pgid:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass

    _term()
    deadline = time.time() + grace
    while time.time() < deadline:
        try:
            os.kill(pid, 0)
            time.sleep(0.05)
        except ProcessLookupError:
            return
    _kill()


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _wait_rc(pid: int) -> int:
    try:
        _wpid, status = os.waitpid(pid, os.WNOHANG)
        if _wpid == 0:
            return 143
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return 128 + os.WTERMSIG(status)
        return 1
    except ChildProcessError:
        return 0


def supervise_agent(
    job_json: str,
    log_path: str,
    pid: int,
    timeout_sec: int,
    runtime: str,
    poll_sec: float = 0.2,
    incident_budget_sec: float | int | None = None,
) -> dict:
    job_path = Path(job_json)
    job_id = job_path.stem
    job_dir = job_path.parent
    deadline = time.time() + max(1, int(timeout_sec))
    budget = incident_io.budget_seconds(incident_budget_sec)
    incident_seen_at: float | None = None
    last_incident_mtime: float | None = None
    rc = 0
    while True:
        log = _read_log(log_path)
        parsed = parse_contract(log)
        if parsed:
            data = finalize_agent_from_log(job_json, log_path, rc=0, runtime=runtime)
            write_done(job_dir, job_id, data["status"])
            kill_process_group(pid)
            return data
        if not _pid_alive(pid):
            rc = _wait_rc(pid)
            data = finalize_agent_from_log(job_json, log_path, rc=rc, runtime=runtime)
            write_done(job_dir, job_id, data["status"])
            return data
        if time.time() >= deadline:
            kill_process_group(pid)
            data = finalize_agent_from_log(job_json, log_path, rc=124, runtime=runtime)
            write_done(job_dir, job_id, data["status"])
            return data

        inc_path = incident_io.incident_path_for_job(job_json)
        if inc_path.is_file():
            try:
                mtime = inc_path.stat().st_mtime
            except OSError:
                mtime = None
            if incident_seen_at is None:
                incident_seen_at = time.time()
            if mtime is not None and mtime != last_incident_mtime:
                apply_incident_sidecar(job_json)
                last_incident_mtime = mtime
            if (
                budget > 0
                and incident_seen_at is not None
                and (time.time() - incident_seen_at) >= budget
            ):
                kill_process_group(pid)
                data = finalize_agent_from_log(
                    job_json,
                    log_path,
                    rc=1,
                    runtime=runtime,
                    fail_reason="incident budget exceeded",
                )
                write_done(job_dir, job_id, data["status"])
                return data
        time.sleep(poll_sec)


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: job_complete.py <supervise|finalize|fail-signal|remaining> ...", file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == "supervise":
        job_json, log_path, pid, timeout_sec, runtime = argv[1:6]
        supervise_agent(job_json, log_path, int(pid), int(timeout_sec), runtime)
        return 0
    if cmd == "finalize":
        job_json, log_path, rc, runtime = argv[1:5]
        data = finalize_agent_from_log(job_json, log_path, int(rc), runtime)
        write_done(Path(job_json).parent, Path(job_json).stem, data["status"])
        return 0
    if cmd == "fail-signal":
        fail_signal_if_missing(argv[1], argv[2])
        return 0
    if cmd == "remaining":
        print(remaining_from_job(argv[1]))
        return 0
    if cmd == "write-done":
        write_done(argv[1], argv[2], argv[3])
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
