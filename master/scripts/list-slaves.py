#!/usr/bin/env python3
"""List slave gateways and resolve partition → gateway for Master routing."""
import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
MASTER_ROOT = SCRIPT_DIR.parent
CONFIG = MASTER_ROOT / "config"
PARTITIONS = CONFIG / "partitions.conf"
SLAVES = CONFIG / "slaves.conf"
MASTER = CONFIG / "master.conf"


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

    print("# Slave registry (from master/config/slaves.conf + partitions.conf)")
    print(f"# Master defaults: gateway={master.get('default_gateway', '?')} partition={master.get('default_partition', '?')}")
    print()
    for row in slaves:
        nodeset = partitions.get(row["partition"], row["nodeset"])
        print(f"gateway={row['gateway']}  partition={row['partition']}  nodeset={nodeset}")
    if not slaves:
        print("(empty — edit master/config/slaves.conf)")


if __name__ == "__main__":
    main()
