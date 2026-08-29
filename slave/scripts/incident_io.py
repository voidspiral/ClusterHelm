"""Sidecar incident records for in-flight agent jobs.

Wrap / workflow_runner write `<job_id>.incident.json`. supervise merges it
into job JSON without finalizing, so Master poll.sh can see failures while
the Slave LLM is still running.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

INCIDENT_ENV = "CLUSTERHELM_INCIDENT_PATH"
BUDGET_ENV = "CLUSTERHELM_INCIDENT_BUDGET_SEC"
DEFAULT_BUDGET_SEC = 120
DETAIL_LIMIT = 2000


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def incident_path_for_job(job_json: str | Path) -> Path:
    path = Path(job_json)
    return path.with_name(f"{path.stem}.incident.json")


def incident_path_from_env() -> Path | None:
    raw = os.environ.get(INCIDENT_ENV, "").strip()
    if raw:
        return Path(raw)
    job_dir = os.environ.get("AGENT_JOB_DIR", "").strip()
    job_id = os.environ.get("AGENT_JOB_ID", "").strip()
    if job_dir and job_id:
        return Path(job_dir) / f"{job_id}.incident.json"
    return None


def load_incident(path: str | Path) -> dict[str, Any] | None:
    file = Path(path)
    if not file.is_file():
        return None
    try:
        data = json.loads(file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def write_incident(path: str | Path, record: dict[str, Any]) -> Path:
    dest = Path(path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    payload = dict(record)
    payload.setdefault("at", utc_now())
    if "detail_tail" in payload and isinstance(payload["detail_tail"], str):
        payload["detail_tail"] = payload["detail_tail"][-DETAIL_LIMIT:]
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    tmp.replace(dest)
    return dest


def write_incident_from_env(record: dict[str, Any]) -> Path | None:
    path = incident_path_from_env()
    if path is None:
        return None
    return write_incident(path, record)


def incident_summary(incident: dict[str, Any]) -> str:
    step = incident.get("step") or "unknown"
    exit_code = incident.get("exit_code")
    reason = incident.get("reason_code")
    hosts = incident.get("hosts") or []
    host_bit = ",".join(str(h) for h in hosts[:8])
    parts = [str(step)]
    if exit_code is not None:
        parts.append(f"exit {exit_code}")
    if reason:
        parts.append(str(reason))
    if host_bit:
        parts.append(host_bit)
    return "; ".join(parts)


def incident_markdown(incident: dict[str, Any] | None) -> str:
    if not incident:
        return ""
    command = incident.get("command") or []
    if isinstance(command, list):
        cmd = " ".join(str(x) for x in command)
    else:
        cmd = str(command)
    detail = (incident.get("detail_tail") or "").strip() or "(none)"
    hosts = incident.get("hosts") or []
    lines = [
        "## Incident",
        f"- Step: {incident.get('step') or '?'}",
        f"- At: {incident.get('at') or '?'}",
        f"- Source: {incident.get('source') or '?'}",
        f"- Exit: {incident.get('exit_code')}",
        f"- Hosts: {', '.join(str(h) for h in hosts) or '(none)'}",
        f"- Reason: {incident.get('reason_code') or '(none)'}",
        f"- Command: `{cmd}`" if cmd else "- Command: (none)",
        "",
        "```",
        detail[-DETAIL_LIMIT:],
        "```",
    ]
    return "\n".join(lines)


def _same_failure(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return (
        left.get("step") == right.get("step")
        and left.get("exit_code") == right.get("exit_code")
        and left.get("command") == right.get("command")
        and left.get("reason_code") == right.get("reason_code")
    )


def failure_entry(incident: dict[str, Any]) -> dict[str, Any]:
    command = incident.get("command")
    return {
        "step": incident.get("step"),
        "at": incident.get("at"),
        "hosts": list(incident.get("hosts") or []),
        "exit_code": incident.get("exit_code"),
        "detail_tail": (incident.get("detail_tail") or "")[-DETAIL_LIMIT:],
        "source": incident.get("source"),
        "reason_code": incident.get("reason_code"),
        "command": command,
    }


def merge_incident_into_job(data: dict[str, Any], incident: dict[str, Any]) -> dict[str, Any]:
    """Update running job JSON. Does not set a terminal status."""
    summary = incident_summary(incident)
    data["summary"] = summary
    data["agent_progress"] = {
        "step": incident.get("step"),
        "status": "incident",
        "summary": summary,
        "at": incident.get("at"),
        "source": incident.get("source"),
    }
    entry = failure_entry(incident)
    failures = list(data.get("failures") or [])
    if failures and _same_failure(failures[-1], entry):
        failures[-1] = entry
    else:
        failures.append(entry)
    data["failures"] = failures
    data["updated_at"] = utc_now()
    return data


def budget_seconds(override: float | int | None = None) -> float:
    if override is not None:
        return float(override)
    raw = os.environ.get(BUDGET_ENV, "").strip()
    if raw:
        return float(raw)
    return float(DEFAULT_BUDGET_SEC)
