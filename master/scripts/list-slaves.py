#!/usr/bin/env python3
"""List slave gateways and resolve partition → gateway for Master routing."""
import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
MASTER_ROOT = SCRIPT_DIR.parent
# Flat deploy: <root>/shared; monorepo: <repo>/shared (sibling of master/)
_shared_candidates = [MASTER_ROOT / "shared", MASTER_ROOT.parent / "shared"]
SHARED = next((p for p in _shared_candidates if (p / "partitions.conf").is_file()), _shared_candidates[-1])
PARTITIONS = SHARED / "partitions.conf"
SLAVES = SHARED / "slaves.conf"
MASTER = MASTER_ROOT / "config" / "master.conf"


def load_partitions():
    m = {}
    if not PARTITIONS.is_file():
        return m
    for line in PARTITIONS.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2:
            m[parts[0]] = parts[1]
    return m


def load_slaves():
    rows = []
    if not SLAVES.is_file():
        return rows
    for line in SLAVES.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 3:
            rows.append({"gateway": parts[0], "partition": parts[1], "nodeset": parts[2]})
    return rows


def load_master():
    cfg = {}
    if not MASTER.is_file():
        return cfg
    for line in MASTER.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            cfg[parts[0]] = parts[1]
    return cfg


def gateway_for_partition(name, slaves, partitions):
    for row in slaves:
        if row["partition"] == name:
            return row["gateway"]
    # direct nodeset: find slave whose owned nodeset matches resolved parent
    resolved = partitions.get(name, name)
    for row in slaves:
        if row["nodeset"] == resolved:
            return row["gateway"]
    return None


def main():
    ap = argparse.ArgumentParser(description="List slaves or resolve gateway for partition")
    ap.add_argument("--partition", help="Logical partition or nodeset; print gateway host")
    ap.add_argument("--json", action="store_true", help="JSON output")
    args = ap.parse_args()

    partitions = load_partitions()
    slaves = load_slaves()
    master = load_master()

    if args.partition:
        gw = gateway_for_partition(args.partition, slaves, partitions)
        if not gw:
            print(f"ERROR: no gateway for partition {args.partition!r}", file=sys.stderr)
            sys.exit(1)
        print(gw)
        return

    if args.json:
        import json
        print(json.dumps({"master": master, "partitions": partitions, "slaves": slaves}, indent=2))
        return

    print("# Slave registry (from shared/slaves.conf + shared/partitions.conf)")
    print(f"# Master defaults: gateway={master.get('default_gateway', '?')} partition={master.get('default_partition', '?')}")
    print()
    for row in slaves:
        nodeset = partitions.get(row["partition"], row["nodeset"])
        print(f"gateway={row['gateway']}  partition={row['partition']}  nodeset={nodeset}")
    if not slaves:
        print("(empty — edit shared/slaves.conf)")


if __name__ == "__main__":
    main()
