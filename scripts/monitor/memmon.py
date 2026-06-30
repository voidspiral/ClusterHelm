#!/usr/bin/env python3
"""Minimal memory collector — single-line JSON to stdout.

Gateway (cn1) keeps this file for ``local`` / ``--remote-cmd``. Partition jobs
must use ``--remote-cmd`` so cn2–cn10 need no deployed copy (simulation phase).
Future: per-node monitoring API with uniform deploy on all nodes.
"""
import base64
import json
import socket
import sys
from pathlib import Path

KB = 1024


def read_meminfo():
    data = {}
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                data[parts[0].rstrip(":")] = int(parts[1])
    return data


def collect():
    info = read_meminfo()
    for key in ("MemTotal", "MemAvailable"):
        if key not in info:
            raise KeyError(key)

    total_kb = info["MemTotal"]
    avail_kb = info["MemAvailable"]
    used_kb = max(total_kb - avail_kb, 0)
    swap_total_kb = info.get("SwapTotal", 0)
    swap_free_kb = info.get("SwapFree", 0)
    swap_used_kb = max(swap_total_kb - swap_free_kb, 0)

    total_mb = round(total_kb / KB)
    used_mb = round(used_kb / KB)
    avail_mb = round(avail_kb / KB)
    used_pct = round((used_kb / total_kb) * 100, 1) if total_kb else 0.0

    host = socket.gethostname().split(".")[0]
    return {
        "host": host,
        "mem_total_mb": total_mb,
        "mem_used_mb": used_mb,
        "mem_avail_mb": avail_mb,
        "mem_used_pct": used_pct,
        "swap_total_mb": round(swap_total_kb / KB),
        "swap_used_mb": round(swap_used_kb / KB),
    }


def remote_cmd():
    """Shell one-liner: no file on target node; needs python3 + base64 + /proc/meminfo."""
    payload = base64.b64encode(Path(__file__).read_bytes()).decode()
    return f"echo {payload} | base64 -d | python3"


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--remote-cmd":
        print(remote_cmd())
        return 0

    try:
        out = collect()
    except OSError as e:
        print(f"memmon: cannot read /proc/meminfo: {e}", file=sys.stderr)
        return 1
    except KeyError as e:
        print(f"memmon: missing {e.args[0]} in /proc/meminfo", file=sys.stderr)
        return 1

    print(json.dumps(out, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
