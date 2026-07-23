#!/usr/bin/env python3
"""Fan out nodestatus summaries to registered Slave gateways only."""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import shlex
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def load_slaves(path: Path) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        parts = line.split()
        if len(parts) >= 3:
            rows.append((parts[0], parts[1]))
    return rows


def query(
    ssh_bin: str, gateway: str, partition: str, timeout: int
) -> tuple[str, dict | None, str | None]:
    remote = (
        "/home/smt/agents/bin/nodestatus summary "
        f"--partition {shlex.quote(partition)} "
        "--socket /run/nodestatus/nodestatus.sock -o json"
    )
    try:
        result = subprocess.run(
            [
                ssh_bin, "-o", f"ConnectTimeout={timeout}", "-o", "BatchMode=yes",
                gateway, remote,
            ],
            capture_output=True,
            text=True,
            timeout=timeout + 5,
        )
        if result.returncode != 0:
            return partition, None, (result.stderr or "ssh failed").strip()[:300]
        payload = json.loads(result.stdout)
        if not isinstance(payload, dict):
            raise ValueError("summary is not a JSON object")
        return partition, {"gateway": gateway, "summary": payload}, None
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        return partition, None, str(exc)[:300]


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--slaves-conf", type=Path, default=root / "master/config/slaves.conf"
    )
    parser.add_argument("--ssh-bin", default="ssh")
    parser.add_argument("--timeout", type=int, default=10)
    args = parser.parse_args()

    rows = load_slaves(args.slaves_conf)
    partitions: dict[str, dict] = {}
    failures: list[dict[str, str]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(rows))) as pool:
        futures = [
            pool.submit(query, args.ssh_bin, gateway, partition, args.timeout)
            for gateway, partition in rows
        ]
        for future in concurrent.futures.as_completed(futures):
            partition, result, error = future.result()
            if result is not None:
                partitions[partition] = result
            else:
                gateway = next(g for g, p in rows if p == partition)
                failures.append(
                    {"partition": partition, "gateway": gateway, "error": error or "unknown"}
                )
    output = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "partial": bool(failures),
        "partitions": {key: partitions[key] for key in sorted(partitions)},
        "failures": sorted(failures, key=lambda item: item["partition"]),
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
