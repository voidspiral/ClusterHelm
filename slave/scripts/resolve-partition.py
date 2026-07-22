#!/usr/bin/env python3
"""Resolve logical partition names (e.g. test) to nodeset expressions.

Looks for partitions.conf under:
  - ../config/partitions.conf  (deployed flat or slave/config copy)
  - ../../master/config/partitions.conf  (monorepo SoT on Master)
"""
import re
import sys
from pathlib import Path

DIR = Path(__file__).resolve().parent
_CANDIDATES = [
    DIR.parent / "config" / "partitions.conf",  # slave/config or /home/smt/agents/config
    DIR.parents[1] / "master" / "config" / "partitions.conf",  # monorepo
]


def _conf_path() -> Path:
    for p in _CANDIDATES:
        if p.is_file():
            return p
    return _CANDIDATES[0]


CONF = _conf_path()


def load_partitions():
    aliases = {}
    conf = _conf_path()
    if not conf.is_file():
        return aliases
    for line in conf.read_text().splitlines():
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
