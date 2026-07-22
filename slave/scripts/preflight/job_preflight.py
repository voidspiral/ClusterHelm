#!/usr/bin/env python3
"""Partition node availability preflight — ping, SSH, persisted exclusions.

Called before exec (script worker) and before Slave agent LLM (agent worker).
Updates job JSON with reachable_hosts, excluded_hosts, per-node ping/ssh state.
"""
from __future__ import annotations

import json
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def expand(expr: str) -> list[str]:
    m = re.match(r"^([a-zA-Z]+)\[(.+)\]$", expr)
    if not m:
        return [expr]
    prefix, inner = m.group(1), m.group(2)
    out: list[str] = []
    for part in inner.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(f"{prefix}{i}" for i in range(int(a), int(b) + 1))
        else:
            out.append(f"{prefix}{part}")
    return out


def run_preflight(job_dir: str | Path, job_id: str, ssh_timeout: int = 60) -> dict:
    preflight_dir = Path(__file__).resolve().parent
    sys.path.insert(0, str(preflight_dir))
    from node_exclude import NodeExclusionStore

    job_dir = Path(job_dir)
    path = job_dir / f"{job_id}.json"
    with open(path) as f:
        data = json.load(f)

    _local = socket.gethostname().split(".")[0].lower()
    partition_name = data.get("partition") or data.get("partition_nodeset", "")
    store = NodeExclusionStore(job_dir)
    hosts = expand(data["partition_nodeset"])

    def save() -> None:
        data["updated_at"] = _utc_now()
        with open(path, "w") as f:
            json.dump(data, f, indent=2)

    def is_local(host: str) -> bool:
        h = host.split(".")[0].lower()
        return h in (_local, "localhost", "127.0.0.1")

    def ssh_run(host: str, *, check_only: bool = False) -> tuple[int, str]:
        if is_local(host):
            return 0, ""
        base = [
            "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new", host, "true",
        ]
        try:
            r = subprocess.run(base, capture_output=True, text=True, timeout=ssh_timeout)
            return r.returncode, (r.stdout or "") + (r.stderr or "")
        except subprocess.TimeoutExpired:
            return 124, "ssh timeout"

    def ping_host(host: str) -> tuple[int, str]:
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

    def preflight_host(host: str) -> tuple[bool, bool, bool, str]:
        if is_local(host):
            return True, True, True, ""
        prc, pout = ping_host(host)
        if prc != 0:
            return False, False, False, f"ping: {pout or 'fail'}"
        src, sout = ssh_run(host, check_only=True)
        if src != 0:
            return False, True, False, f"ssh: {sout.strip()[:200] or 'fail'}"
        return True, True, True, ""

    if "nodes" not in data:
        data["nodes"] = {}
    if "failures" not in data:
        data["failures"] = []

    data["progress"] = {"total": len(hosts), "ok": 0, "fail": 0, "pending": len(hosts), "excluded": 0}
    data["reachable_hosts"] = data.get("reachable_hosts") or []
    data["excluded_hosts"] = []
    data["newly_excluded"] = data.get("newly_excluded") or []
    data["status"] = "preflight"
    data["phase"] = "preflight"
    save()

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
            "exclude_reason": entry.get("reason") if entry else None,
            "excluded_since": entry.get("excluded_since") if entry else None,
            "last_fail_at": entry.get("last_fail_at") if entry else None,
        }
        data["progress"]["excluded"] = excluded_skip
        save()

    ok = fail = 0
    reachable: list[str] = []
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
        save()

    return data


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: job_preflight.py JOB_DIR JOB_ID [SSH_TIMEOUT]", file=sys.stderr)
        sys.exit(1)
    job_dir, job_id = sys.argv[1], sys.argv[2]
    ssh_timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    run_preflight(job_dir, job_id, ssh_timeout)


if __name__ == "__main__":
    main()
