#!/usr/bin/env python3
"""Append-only structured lifecycle events for Slave jobs."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def event_path(job_dir: str | Path, job_id: str) -> Path:
    return Path(job_dir) / f"{job_id}.events.jsonl"


def append_event(
    job_dir: str | Path,
    job_id: str,
    phase: str,
    *,
    state: str,
    source: str | None = None,
    **details: Any,
) -> Path:
    """Append one valid JSON line while serializing concurrent writers."""
    path = event_path(job_dir, job_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        row: dict[str, Any] = {
            "at": datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
                "+00:00", "Z"
            ),
            "monotonic_ns": time.monotonic_ns(),
            "job_id": job_id,
            "phase": phase,
            "state": state,
        }
        if source:
            row["source"] = source
        row.update(details)
        stream.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
    return path


def _parse_detail(raw: str) -> tuple[str, Any]:
    if "=" not in raw:
        raise argparse.ArgumentTypeError("detail must be key=value")
    key, value = raw.split("=", 1)
    if not key:
        raise argparse.ArgumentTypeError("detail key is empty")
    try:
        return key, json.loads(value)
    except json.JSONDecodeError:
        return key, value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("job_dir")
    parser.add_argument("job_id")
    parser.add_argument("phase")
    parser.add_argument("state")
    parser.add_argument("--source")
    parser.add_argument("--detail", action="append", default=[], type=_parse_detail)
    args = parser.parse_args(argv)
    append_event(
        args.job_dir,
        args.job_id,
        args.phase,
        state=args.state,
        source=args.source,
        **dict(args.detail),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
