#!/usr/bin/env python3
"""Resolve logical partition names (e.g. test) to nodeset expressions."""
import re
import sys
from pathlib import Path

DIR = Path(__file__).resolve().parent
CONF = DIR / "partitions.conf"


def load_partitions():
    aliases = {}
    if not CONF.is_file():
        return aliases
    for line in CONF.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2:
            aliases[parts[0]] = parts[1]
    return aliases


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


def all_owned_hosts():
    owned = set()
    for nodeset in load_partitions().values():
        owned.update(expand(nodeset))
    return owned


def resolve(name):
    aliases = load_partitions()
    return aliases.get(name, name)


def validate_subset(nodeset):
    hosts = set(expand(nodeset))
    owned = all_owned_hosts()
    if not owned:
        return nodeset
    extra = hosts - owned
    if extra:
        owned_list = ", ".join(sorted(load_partitions()))
        raise SystemExit(
            f"hosts {sorted(extra)} outside owned partitions ({owned_list}); see partitions.conf"
        )
    return nodeset


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <partition> [--validate]", file=sys.stderr)
        sys.exit(1)
    name = sys.argv[1]
    nodeset = resolve(name)
    if len(sys.argv) > 2 and sys.argv[2] == "--validate":
        validate_subset(nodeset)
    print(nodeset)


if __name__ == "__main__":
    main()
