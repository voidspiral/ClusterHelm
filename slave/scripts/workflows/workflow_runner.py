#!/usr/bin/env python3
"""Deterministic, single-call workflow runner for the Slave agent."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


class ArgumentError(ValueError):
    pass


def load_catalog(workflow_dir: Path) -> dict[str, dict[str, Any]]:
    catalog: dict[str, dict[str, Any]] = {}
    if not workflow_dir.is_dir():
        return catalog
    for path in sorted(workflow_dir.glob("*.json")):
        try:
            item = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"invalid workflow definition {path}: {exc}") from exc
        workflow_id = item.get("id")
        if not isinstance(workflow_id, str) or not workflow_id:
            raise RuntimeError(f"workflow definition has no id: {path}")
        if workflow_id in catalog:
            raise RuntimeError(f"duplicate workflow id: {workflow_id}")
        item["_definition_path"] = str(path)
        catalog[workflow_id] = item
    return catalog


def _parse_raw_args(raw_args: list[str]) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw in raw_args:
        if "=" not in raw:
            raise ArgumentError(f"argument must be key=value: {raw}")
        key, value = raw.split("=", 1)
        if not key or key in parsed:
            raise ArgumentError(f"invalid or duplicate argument: {key or raw}")
        parsed[key] = value
    return parsed


def validate_arguments(
    workflow: dict[str, Any], raw_args: list[str]
) -> dict[str, Any]:
    supplied = _parse_raw_args(raw_args)
    schema = workflow.get("arguments", {})
    unknown = sorted(set(supplied) - set(schema))
    if unknown:
        raise ArgumentError(f"unknown argument(s): {', '.join(unknown)}")

    result: dict[str, Any] = {}
    for name, rule in schema.items():
        if name in supplied:
            raw: Any = supplied[name]
        elif "default" in rule:
            raw = rule["default"]
        elif rule.get("required"):
            raise ArgumentError(f"missing required argument: {name}")
        else:
            continue

        arg_type = rule.get("type", "string")
        if arg_type == "integer":
            try:
                value = int(raw)
            except (TypeError, ValueError) as exc:
                raise ArgumentError(f"{name} must be an integer") from exc
            if "minimum" in rule and value < int(rule["minimum"]):
                raise ArgumentError(f"{name} must be >= {rule['minimum']}")
            if "maximum" in rule and value > int(rule["maximum"]):
                raise ArgumentError(f"{name} must be <= {rule['maximum']}")
        elif arg_type == "string":
            value = str(raw)
            if len(value) < int(rule.get("min_length", 0)):
                raise ArgumentError(f"{name} is too short")
        elif arg_type == "boolean":
            lowered = str(raw).lower()
            if lowered not in {"true", "false"}:
                raise ArgumentError(f"{name} must be true or false")
            value = lowered == "true"
        else:
            raise ArgumentError(f"unsupported type for {name}: {arg_type}")
        result[name] = value
    return result


def classify_job(
    job: dict[str, Any], workflow: dict[str, Any]
) -> tuple[str, str]:
    report = job.get("partition_report")
    if not isinstance(report, dict) or not report.get("markdown"):
        return "exception", "contract_error"
    status = job.get("status")
    if status == "done":
        return "success", "ok"
    if status == "partial":
        exec_fail = report.get("exec_fail") or []
        allow_partial = workflow.get("success_policy", {}).get(
            "allow_exclusion_only_partial", False
        )
        if allow_partial and not exec_fail:
            return "success", "ok"
        return "exception", "execution_error"
    if status == "failed":
        summary = str(job.get("summary", "")).lower()
        if "timeout" in summary or "deadline" in summary:
            return "exception", "timeout"
        return "exception", "execution_error"
    return "exception", "contract_error"


def _layout(agent_root: Path) -> dict[str, Path]:
    agent_root = agent_root.resolve()
    repo_root = agent_root.parent if agent_root.name == "slave" else agent_root
    shared_scripts = repo_root / "scripts"
    return {
        "agent_root": agent_root,
        "workflow_dir": agent_root / "workflows",
        "run_slave": agent_root / "scripts/run-slave.sh",
        "monitor_dir": shared_scripts / "monitor"
        if (shared_scripts / "monitor").is_dir()
        else agent_root / "scripts/monitor",
        "mpi_dir": shared_scripts / "mpi"
        if (shared_scripts / "mpi").is_dir()
        else agent_root / "scripts/mpi",
    }


def _exception(
    workflow_id: str,
    reason_code: str,
    attempt: int,
    max_attempts: int,
    message: str,
    *,
    job: dict[str, Any] | None = None,
) -> dict[str, Any]:
    report = (job or {}).get("partition_report") or {}
    return {
        "workflow_id": workflow_id,
        "outcome": "exception",
        "reason_code": reason_code,
        "attempt": attempt,
        "max_attempts": max_attempts,
        "retry_allowed": attempt < max_attempts
        and reason_code
        in {"implementation_missing", "execution_error", "timeout", "contract_error"},
        "message": message,
        "job": job or {},
        "partition_report": report,
    }


def _submit_and_wait(
    run_slave: Path,
    partition: str,
    command: str,
    task: str,
    timeout: int,
) -> dict[str, Any]:
    submit = subprocess.run(
        [
            str(run_slave),
            "submit",
            "--partition",
            partition,
            "--command",
            command,
            "--task",
            task,
            "--deadline",
            str(timeout),
        ],
        capture_output=True,
        text=True,
        timeout=min(timeout, 60),
    )
    if submit.returncode != 0:
        raise RuntimeError(
            f"submit failed ({submit.returncode}): "
            f"{(submit.stderr or submit.stdout).strip()}"
        )
    match = re.search(r"^job_id=(\S+)$", submit.stdout, re.MULTILINE)
    if not match:
        raise RuntimeError(f"submit contract missing job_id: {submit.stdout.strip()}")
    job_id = match.group(1)
    waited = subprocess.run(
        [
            str(run_slave),
            "wait",
            "--job-id",
            job_id,
            "--timeout",
            str(timeout),
        ],
        capture_output=True,
        text=True,
        timeout=timeout + 15,
    )
    if waited.returncode != 0:
        raise RuntimeError(
            f"wait failed ({waited.returncode}) for {job_id}: "
            f"{(waited.stderr or waited.stdout).strip()}"
        )
    try:
        return json.loads(waited.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"wait returned invalid JSON for {job_id}") from exc


def _render_command(
    workflow: dict[str, Any],
    arguments: dict[str, Any],
    layout: dict[str, Path],
) -> str:
    implementation = workflow["implementation"]
    if "command" in implementation:
        return str(implementation["command"])
    if "command_argument" in implementation:
        return str(arguments[implementation["command_argument"]])
    factory = implementation.get("command_factory")
    if factory:
        context = {key: str(value) for key, value in layout.items()}
        argv = [str(token).format(**context, **arguments) for token in factory]
        missing = Path(argv[1]) if len(argv) > 1 and "/" in argv[1] else None
        if missing and not missing.exists():
            raise FileNotFoundError(str(missing))
        made = subprocess.run(
            argv, capture_output=True, text=True, timeout=30
        )
        if made.returncode != 0 or not made.stdout.strip():
            raise RuntimeError(
                f"command factory failed: {(made.stderr or made.stdout).strip()}"
            )
        return made.stdout.strip()
    raise FileNotFoundError("workflow has no deterministic command")


def _format_memory_report(job: dict[str, Any]) -> None:
    report = job.get("partition_report")
    if not isinstance(report, dict):
        return
    rows: list[dict[str, Any]] = []
    for node in job.get("nodes", {}).values():
        if node.get("state") != "ok" or node.get("phase") != "exec":
            continue
        raw = (node.get("stdout") or "").strip().splitlines()
        if not raw:
            continue
        try:
            rows.append(json.loads(raw[0]))
        except json.JSONDecodeError:
            continue
    if not rows:
        return
    lines = [
        report.get("markdown", ""),
        "",
        "## Memory",
        "",
        "| Host | Used | Total | Used % | Swap used |",
        "|------|------|-------|--------|-----------|",
    ]
    for row in sorted(rows, key=lambda item: str(item.get("host", ""))):
        lines.append(
            f"| {row.get('host', '?')} | {row.get('mem_used_mb', '?')} MB | "
            f"{row.get('mem_total_mb', '?')} MB | "
            f"{row.get('mem_used_pct', '?')}% | "
            f"{row.get('swap_used_mb', '?')} MB |"
        )
    report["markdown"] = "\n".join(lines)
    report["memory"] = rows


def _run_gateway_script(
    workflow: dict[str, Any],
    partition: str,
    arguments: dict[str, Any],
    timeout: int,
    layout: dict[str, Path],
) -> dict[str, Any]:
    job = _submit_and_wait(
        layout["run_slave"],
        partition,
        "true",
        f"workflow:{workflow['id']}:preflight",
        timeout,
    )
    outcome, _ = classify_job(job, workflow)
    if outcome != "success":
        return job

    context = {
        **{key: str(value) for key, value in layout.items()},
        **{key: str(value) for key, value in arguments.items()},
        "partition": partition,
    }
    argv = [
        str(token).format(**context)
        for token in workflow["implementation"].get("argv", [])
    ]
    if not argv or not Path(argv[0]).exists():
        raise FileNotFoundError(argv[0] if argv else "gateway script")
    env = os.environ.copy()
    env["CLUSTERHELM_REACHABLE_HOSTS"] = " ".join(
        job.get("reachable_hosts", [])
    )
    completed = subprocess.run(
        argv, capture_output=True, text=True, timeout=timeout, env=env
    )
    output = ((completed.stdout or "") + (completed.stderr or "")).strip()
    report = job["partition_report"]
    report["markdown"] = (
        f"{report['markdown']}\n\n## Gateway workflow: {workflow['id']}\n\n"
        f"- Exit: {completed.returncode}\n\n```\n{output[-4000:] or '(no output)'}\n```"
    )
    report["gateway_exit_code"] = completed.returncode
    report["gateway_output"] = output[-4000:]
    if completed.returncode != 0:
        job["status"] = "failed"
        report["status"] = "failed"
        report["summary_line"] = f"{workflow['id']} failed (exit={completed.returncode})"
        job["summary"] = report["summary_line"]
    return job


def run_workflow(
    *,
    workflow_id: str,
    partition: str,
    raw_args: list[str],
    attempt: int,
    timeout: int,
    agent_root: Path,
) -> dict[str, Any]:
    layout = _layout(agent_root)
    catalog = load_catalog(layout["workflow_dir"])
    workflow = catalog.get(workflow_id)
    if workflow is None:
        return _exception(
            workflow_id, "workflow_missing", attempt, 1, "workflow is not registered"
        )
    max_attempts = int(workflow.get("max_attempts", 1))
    if attempt < 1 or attempt > max_attempts:
        return _exception(
            workflow_id,
            "retry_budget_exceeded",
            attempt,
            max_attempts,
            f"attempt must be between 1 and {max_attempts}",
        )
    try:
        arguments = validate_arguments(workflow, raw_args)
    except ArgumentError as exc:
        return _exception(
            workflow_id, "invalid_arguments", attempt, max_attempts, str(exc)
        )

    try:
        implementation_type = workflow.get("implementation", {}).get("type")
        if implementation_type == "per-node-command":
            command = _render_command(workflow, arguments, layout)
            job = _submit_and_wait(
                layout["run_slave"],
                partition,
                command,
                f"workflow:{workflow_id}",
                timeout,
            )
        elif implementation_type == "gateway-script":
            job = _run_gateway_script(
                workflow, partition, arguments, timeout, layout
            )
        else:
            raise FileNotFoundError(
                f"unsupported implementation type: {implementation_type}"
            )
    except FileNotFoundError as exc:
        return _exception(
            workflow_id,
            "implementation_missing",
            attempt,
            max_attempts,
            str(exc),
        )
    except subprocess.TimeoutExpired as exc:
        return _exception(
            workflow_id,
            "timeout",
            attempt,
            max_attempts,
            f"deterministic execution timed out after {exc.timeout}s",
        )
    except (OSError, RuntimeError) as exc:
        return _exception(
            workflow_id,
            "execution_error",
            attempt,
            max_attempts,
            str(exc),
        )

    if workflow.get("implementation", {}).get("report_formatter") == "memory":
        _format_memory_report(job)
    outcome, reason_code = classify_job(job, workflow)
    report = job.get("partition_report") or {}
    return {
        "workflow_id": workflow_id,
        "arguments": arguments,
        "outcome": outcome,
        "reason_code": reason_code,
        "attempt": attempt,
        "max_attempts": max_attempts,
        "retry_allowed": outcome == "exception" and attempt < max_attempts,
        "message": job.get("summary") or report.get("summary_line"),
        "job": job,
        "partition_report": report,
    }


def _default_agent_root() -> Path:
    return Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--agent-root", type=Path, default=_default_agent_root(), help=argparse.SUPPRESS
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    describe = sub.add_parser("describe")
    describe.add_argument("workflow_id")
    run = sub.add_parser("run")
    run.add_argument("workflow_id")
    run.add_argument("--partition", required=True)
    run.add_argument("--arg", action="append", default=[])
    run.add_argument("--attempt", type=int, default=1)
    run.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args(argv)

    catalog = load_catalog(args.agent_root / "workflows")
    if args.command == "list":
        result: Any = [
            {
                "id": item["id"],
                "title": item.get("title"),
                "match_hints": item.get("match_hints", []),
                "arguments": item.get("arguments", {}),
            }
            for item in catalog.values()
        ]
    elif args.command == "describe":
        result = catalog.get(args.workflow_id)
        if result is None:
            result = {
                "outcome": "exception",
                "reason_code": "workflow_missing",
                "workflow_id": args.workflow_id,
            }
    else:
        result = run_workflow(
            workflow_id=args.workflow_id,
            partition=args.partition,
            raw_args=args.arg,
            attempt=args.attempt,
            timeout=args.timeout,
            agent_root=args.agent_root,
        )
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
