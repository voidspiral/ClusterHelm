#!/usr/bin/env python3
"""Gateway-local vs nodeset execution scope for script-mode jobs."""
from __future__ import annotations

import re


def resolve_exec_scope(explicit: str | None, command: str | None) -> str:
    if explicit in {"gateway", "nodeset"}:
        return explicit
    cmd = command or ""
    if re.search(r"\b(mpirun|mpiexec)\b", cmd):
        return "gateway"
    return "nodeset"


def exec_hosts(scope: str, partition_hosts: list[str], gateway_host: str) -> list[str]:
    if scope == "gateway":
        return [gateway_host]
    return list(partition_hosts)
