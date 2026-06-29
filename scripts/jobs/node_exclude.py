#!/usr/bin/env python3
"""Persistent per-partition node exclusion for Slave gateways."""
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_STORE = "node-exclusions.json"


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_ts(ts: str | None) -> datetime | None:
    if not ts:
        return None
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def load_slave_conf(script_dir: Path | None = None) -> dict[str, Any]:
    script_dir = script_dir or Path(__file__).resolve().parent
    conf_path = script_dir / "slave.conf"
    out: dict[str, Any] = {
        "exclude_store": DEFAULT_STORE,
        "exclude_preflight_fail": True,
        "exclude_exec_fail_threshold": 3,
        "exclude_ttl_seconds": 3600,
    }
    if not conf_path.is_file():
        return out
    for line in conf_path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        key, val = parts
        if key in ("exclude_preflight_fail",):
            out[key] = val.lower() in ("1", "true", "yes", "on")
        elif key in ("exclude_exec_fail_threshold", "exclude_ttl_seconds"):
            out[key] = int(val)
        else:
            out[key] = val
    return out


class NodeExclusionStore:
    def __init__(self, job_dir: str | Path, conf: dict[str, Any] | None = None):
        self.job_dir = Path(job_dir)
        self.conf = conf or load_slave_conf()
        name = self.conf.get("exclude_store", DEFAULT_STORE)
        self.path = self.job_dir / name
        self._data: dict[str, dict[str, dict[str, Any]]] | None = None

    def _load(self) -> dict[str, dict[str, dict[str, Any]]]:
        if self._data is not None:
            return self._data
        if self.path.is_file():
            with open(self.path) as f:
                raw = json.load(f)
            self._data = raw if isinstance(raw, dict) else {}
        else:
            self._data = {}
        self._prune_expired()
        return self._data

    def _save(self) -> None:
        self.job_dir.mkdir(parents=True, exist_ok=True)
        with open(self.path, "w") as f:
            json.dump(self._data or {}, f, indent=2)

    def _ttl_seconds(self) -> int:
        return int(self.conf.get("exclude_ttl_seconds", 0) or 0)

    def _partition(self, partition: str) -> dict[str, dict[str, Any]]:
        data = self._load()
        return data.setdefault(partition, {})

    def _is_entry_active(self, entry: dict[str, Any]) -> bool:
        if not entry.get("excluded"):
            return False
        ttl = self._ttl_seconds()
        if ttl <= 0:
            return True
        since = _parse_ts(entry.get("excluded_since"))
        if since is None:
            return True
        age = (datetime.now(timezone.utc) - since).total_seconds()
        return age < ttl

    def _prune_expired(self) -> None:
        if self._data is None:
            return
        ttl = self._ttl_seconds()
        if ttl <= 0:
            return
        changed = False
        for part, hosts in list(self._data.items()):
            for host, entry in list(hosts.items()):
                if entry.get("excluded") and not self._is_entry_active(entry):
                    entry["excluded"] = False
                    entry["cleared_at"] = _utc_now()
                    entry["clear_reason"] = "ttl_expired"
                    changed = True
        if changed:
            self._save()

    def get_entry(self, partition: str, host: str) -> dict[str, Any] | None:
        entry = self._partition(partition).get(host)
        if not entry or not self._is_entry_active(entry):
            return None
        return entry

    def is_excluded(self, partition: str, host: str) -> tuple[bool, dict[str, Any] | None]:
        entry = self.get_entry(partition, host)
        return (entry is not None, entry)

    def list_excluded(self, partition: str) -> list[tuple[str, dict[str, Any]]]:
        part = self._partition(partition)
        out = []
        for host, entry in part.items():
            if self._is_entry_active(entry):
                out.append((host, entry))
        return sorted(out, key=lambda x: x[0])

    def exclude(
        self,
        partition: str,
        host: str,
        *,
        reason: str,
        phase: str,
        fail_count: int | None = None,
    ) -> dict[str, Any]:
        part = self._partition(partition)
        now = _utc_now()
        prev = part.get(host, {})
        entry = {
            "excluded": True,
            "excluded_since": prev.get("excluded_since") if self._is_entry_active(prev) else now,
            "last_excluded_at": now,
            "reason": reason,
            "phase": phase,
            "fail_count": fail_count if fail_count is not None else prev.get("fail_count", 1),
            "last_error": reason,
            "last_fail_at": now,
        }
        part[host] = entry
        self._save()
        return entry

    def record_preflight_failure(self, partition: str, host: str, error: str) -> bool:
        """Return True if node is (newly or still) excluded."""
        if self.conf.get("exclude_preflight_fail", True):
            self.exclude(partition, host, reason=error, phase="preflight", fail_count=1)
            return True
        return self.record_exec_failure(partition, host, error, phase="preflight") is not None

    def record_exec_failure(
        self, partition: str, host: str, error: str, *, phase: str = "exec"
    ) -> dict[str, Any] | None:
        threshold = max(1, int(self.conf.get("exclude_exec_fail_threshold", 3)))
        part = self._partition(partition)
        prev = part.get(host, {})
        if self._is_entry_active(prev):
            return prev
        streak = int(prev.get("exec_fail_streak", 0)) + 1
        now = _utc_now()
        part[host] = {
            **prev,
            "excluded": False,
            "exec_fail_streak": streak,
            "last_error": error,
            "last_fail_at": now,
            "last_phase": phase,
        }
        if streak >= threshold:
            entry = self.exclude(
                partition,
                host,
                reason=f"{streak} consecutive {phase} failures: {error}",
                phase=phase,
                fail_count=streak,
            )
            self._save()
            return entry
        self._save()
        return None

    def record_success(self, partition: str, host: str) -> None:
        part = self._partition(partition)
        if host not in part:
            return
        entry = part[host]
        if not self._is_entry_active(entry):
            entry.pop("exec_fail_streak", None)
        else:
            return
        entry["exec_fail_streak"] = 0
        entry["last_ok_at"] = _utc_now()
        self._save()

    def clear(self, partition: str, host: str) -> None:
        part = self._partition(partition)
        if host not in part:
            return
        part[host]["excluded"] = False
        part[host]["cleared_at"] = _utc_now()
        part[host]["clear_reason"] = "manual"
        part[host]["exec_fail_streak"] = 0
        self._save()


def _job_dir() -> Path:
    return Path(os.environ.get("AGENT_JOB_DIR", "/var/agent-jobs"))


def main() -> None:
    ap = argparse.ArgumentParser(description="Partition node exclusion store")
    ap.add_argument("--job-dir", default=str(_job_dir()))
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="List excluded nodes for partition")
    p_list.add_argument("--partition", required=True)

    p_clear = sub.add_parser("clear", help="Clear exclusion for one node")
    p_clear.add_argument("--partition", required=True)
    p_clear.add_argument("--host", required=True)

    p_check = sub.add_parser("check", help="Check if host is excluded")
    p_check.add_argument("--partition", required=True)
    p_check.add_argument("--host", required=True)

    args = ap.parse_args()
    store = NodeExclusionStore(args.job_dir)

    if args.cmd == "list":
        rows = store.list_excluded(args.partition)
        if not rows:
            print("[]")
            return
        print(json.dumps([{"host": h, **e} for h, e in rows], indent=2))

    elif args.cmd == "clear":
        store.clear(args.partition, args.host)
        print(f"cleared {args.partition}/{args.host}")

    elif args.cmd == "check":
        excluded, entry = store.is_excluded(args.partition, args.host)
        print(json.dumps({"excluded": excluded, "entry": entry}, indent=2))


if __name__ == "__main__":
    main()
