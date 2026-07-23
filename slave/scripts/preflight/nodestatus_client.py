#!/usr/bin/env python3
"""Small, failure-tolerant client for the partition-local nodestatus daemon."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any


def load_conf(script_dir: Path | None = None) -> dict[str, str]:
    here = script_dir or Path(__file__).resolve().parent
    candidates = [
        here.parent.parent / "config" / "slave.conf",
        here.parent / "config" / "slave.conf",
        here / "slave.conf",
    ]
    values = {
        "nodestatus_enabled": "true",
        "nodestatus_bin": "/home/smt/agents/bin/nodestatus",
        "nodestatus_gateway_config": "/etc/nodestatus/gateway.conf",
        "nodestatus_query_timeout": "5",
        "nodestatus_unix_socket": "/run/nodestatus/nodestatus.sock",
    }
    path = next((candidate for candidate in candidates if candidate.is_file()), None)
    if path:
        for raw in path.read_text().splitlines():
            line = raw.split("#", 1)[0].strip()
            parts = line.split(None, 1)
            if len(parts) == 2:
                values[parts[0]] = parts[1]
    return values


def enabled(conf: dict[str, Any]) -> bool:
    return str(conf.get("nodestatus_enabled", "true")).lower() in {
        "1", "true", "yes", "on",
    }


def _nodes(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [node for node in payload if isinstance(node, dict)]
    if not isinstance(payload, dict):
        return []
    nodes = payload.get("nodes", [])
    if isinstance(nodes, dict):
        return [
            {"host": host, **node}
            for host, node in nodes.items()
            if isinstance(node, dict)
        ]
    return [node for node in nodes if isinstance(node, dict)]


def query_partition(
    partition: str, conf: dict[str, Any] | None = None
) -> tuple[dict[str, dict[str, Any]] | None, dict[str, Any] | None]:
    """Return node map and report metadata, or (None, None) on any CLI failure."""
    conf = conf or load_conf()
    if not enabled(conf):
        return None, None
    binary = os.environ.get(
        "NODESTATUS_BIN",
        str(conf.get("nodestatus_bin") or "/home/smt/agents/bin/nodestatus"),
    )
    socket_path = str(
        conf.get("nodestatus_unix_socket")
        or "/run/nodestatus/nodestatus.sock"
    )
    try:
        result = subprocess.run(
            [
                binary, "list", "--partition", partition,
                "--socket", socket_path, "-o", "json",
            ],
            capture_output=True,
            text=True,
            timeout=max(1, int(conf.get("nodestatus_query_timeout", 5))),
        )
        if result.returncode != 0:
            return None, None
        payload = json.loads(result.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None, None

    nodes = _nodes(payload)
    by_host = {
        str(node.get("host") or node.get("hostname")): node
        for node in nodes
        if node.get("host") or node.get("hostname")
    }
    root = payload if isinstance(payload, dict) else {}
    state_counts = root.get("state_counts")
    if not isinstance(state_counts, dict):
        state_counts = {}
        for node in nodes:
            state = str(node.get("state") or "unknown")
            state_counts[state] = state_counts.get(state, 0) + 1
    freshness_counts = root.get("freshness_counts")
    if not isinstance(freshness_counts, dict):
        freshness_counts = {
            "fresh": sum(node.get("fresh") is True for node in nodes),
            "stale": sum(node.get("fresh") is not True for node in nodes),
        }
    metadata = {
        "snapshot_time": (
            root.get("generated_at")
            or root.get("snapshot_time")
            or root.get("updated_at")
        ),
        "freshness_counts": freshness_counts,
        "state_counts": state_counts,
        "query_source": "nodestatus",
    }
    return by_host, metadata


def probe_partition(
    partition: str,
    hosts: list[str],
    conf: dict[str, Any] | None = None,
) -> tuple[dict[str, dict[str, Any]] | None, dict[str, Any] | None]:
    """Ask the gateway daemon to refresh hosts; callers fall back on failure."""
    conf = conf or load_conf()
    if not enabled(conf) or not hosts:
        return None, None
    binary = os.environ.get(
        "NODESTATUS_BIN",
        str(conf.get("nodestatus_bin") or "/home/smt/agents/bin/nodestatus"),
    )
    socket_path = str(
        conf.get("nodestatus_unix_socket")
        or "/run/nodestatus/nodestatus.sock"
    )
    try:
        result = subprocess.run(
            [
                binary, "probe", "--partition", partition,
                "--hosts", ",".join(hosts), "--socket", socket_path, "-o", "json",
            ],
            capture_output=True,
            text=True,
            timeout=max(1, int(conf.get("nodestatus_query_timeout", 5))) + 30,
        )
        if result.returncode != 0:
            return None, None
        payload = json.loads(result.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None, None
    nodes = _nodes(payload)
    by_host = {
        str(node.get("host") or node.get("hostname")): node
        for node in nodes
        if node.get("host") or node.get("hostname")
    }
    root = payload if isinstance(payload, dict) else {}
    metadata = {
        "snapshot_time": root.get("generated_at"),
        "freshness_counts": {
            "fresh": sum(node.get("fresh") is True for node in nodes),
            "stale": sum(node.get("fresh") is not True for node in nodes),
        },
        "state_counts": {
            state: sum(str(node.get("state") or "unknown") == state for node in nodes)
            for state in ("online", "offline", "degraded", "excluded", "unknown")
        },
        "query_source": "nodestatus_probe",
    }
    return by_host, metadata


def is_fresh_online(node: dict[str, Any] | None) -> bool:
    if not node:
        return False
    exclusion = node.get("exclusion")
    excluded = node.get("excluded") is True or (
        isinstance(exclusion, dict) and exclusion.get("excluded") is True
    )
    return (
        node.get("fresh") is True
        and str(node.get("state", "")).lower() == "online"
        and not excluded
    )


def is_excluded(node: dict[str, Any] | None) -> bool:
    if not node:
        return False
    exclusion = node.get("exclusion")
    return node.get("state") == "excluded" or node.get("excluded") is True or (
        isinstance(exclusion, dict) and exclusion.get("excluded") is True
    )
