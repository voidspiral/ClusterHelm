#!/usr/bin/env python3
"""Deterministic gateway-sidecar workflow for MPI process monitoring."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
from job_events import append_event  # noqa: E402


def _bool(raw: str) -> bool:
    value = raw.lower()
    if value not in {"true", "false"}:
        raise argparse.ArgumentTypeError("expected true or false")
    return value == "true"


def _mpi_monitor_argv(agent_root: Path) -> tuple[list[str], dict[str, str]]:
    env = os.environ.copy()
    installed = shutil.which("mpi-monitor")
    if installed:
        return [installed], env
    vendor = agent_root / "vendor/mpi-monitor"
    venv = vendor / ".venv/bin/mpi-monitor"
    if venv.is_file():
        return [str(venv)], env
    source = vendor / "src"
    if source.is_dir():
        env["PYTHONPATH"] = str(source) + os.pathsep + env.get("PYTHONPATH", "")
        return [sys.executable, "-m", "mpi_monitor"], env
    raise FileNotFoundError("mpi-monitor CLI is not installed on the gateway")


def _load_parent_job(job_dir: Path, job_id: str) -> dict[str, Any]:
    path = job_dir / f"{job_id}.json"
    with path.open() as stream:
        return json.load(stream)


def _select_hosts(parent: dict[str, Any], requested: str, count: int) -> list[str]:
    reachable = list(parent.get("reachable_hosts") or [])
    if requested:
        hosts = [host.strip() for host in requested.split(",") if host.strip()]
        unavailable = [host for host in hosts if host not in reachable]
        if unavailable:
            raise ValueError(f"requested hosts are not reachable: {', '.join(unavailable)}")
    else:
        hosts = reachable[:count]
    if len(hosts) != count:
        raise ValueError(f"need {count} reachable hosts, selected {len(hosts)}")
    return hosts


def _series_summary(series_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(series_dir.glob("*.jsonl")):
        samples = []
        for line in path.read_text(errors="replace").splitlines():
            try:
                samples.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        if not samples:
            continue
        rows.append(
            {
                "file": path.name,
                "host": samples[0].get("host"),
                "pid": samples[0].get("pid"),
                "rank": samples[0].get("rank"),
                "samples": len(samples),
                "cpu_max": max(float(row.get("cpu_pct") or 0) for row in samples),
                "rss_max_mb": max(float(row.get("rss_mb") or 0) for row in samples),
                "io_read_max_bps": max(
                    float(row.get("io_read_bps") or 0) for row in samples
                ),
                "io_write_max_bps": max(
                    float(row.get("io_write_bps") or 0) for row in samples
                ),
            }
        )
    return rows


def _report(
    parent: dict[str, Any],
    *,
    status: str,
    summary: str,
    hosts: list[str],
    command: list[str],
    run_id: str,
    run_dir: Path,
    meta: dict[str, Any],
    series: list[dict[str, Any]],
    charts: list[Path],
    stdout_path: Path,
    stderr_path: Path,
    include_raw: bool,
) -> dict[str, Any]:
    lines = [
        f"# MPI process monitor: {parent.get('partition')} "
        f"({parent.get('partition_nodeset')})",
        "",
        f"- Status: {status}",
        "- monitor_backend=mpi-monitor",
        f"- monitor_run_id={run_id}",
        f"- monitor_meta_path={run_dir / 'meta.json'}",
        f"- monitor_series_count={len(series)}",
        f"- monitor_chart_count={len(charts)}",
        f"- application_exit_code={meta.get('application_exit_code', meta.get('exit_code'))}",
        f"- collection_status={meta.get('collection_status', 'unknown')}",
        f"- Hosts: {', '.join(hosts)}",
        f"- Command: `{' '.join(command)}`",
        "",
        "## Per-rank resources",
        "",
        "| Host | PID | Rank | Samples | CPU max % | RSS max MB | Read max B/s | Write max B/s |",
        "|------|-----|------|---------|-----------|------------|--------------|---------------|",
    ]
    for row in series:
        lines.append(
            f"| {row['host']} | {row['pid']} | {row['rank']} | {row['samples']} | "
            f"{row['cpu_max']:.2f} | {row['rss_max_mb']:.2f} | "
            f"{row['io_read_max_bps']:.0f} | {row['io_write_max_bps']:.0f} |"
        )
    lines.extend(
        [
            "",
            "## Artifacts",
            f"- stdout: {stdout_path}",
            f"- stderr: {stderr_path}",
            f"- series: {run_dir / 'series'}",
            f"- charts: {run_dir / 'charts'}",
        ]
    )
    if meta.get("collect_errors"):
        lines.append(
            "- collect_errors: `"
            + json.dumps(meta["collect_errors"], ensure_ascii=False)
            + "`"
        )
    if include_raw:
        raw = stdout_path.read_text(errors="replace")
        if len(raw) <= 12000:
            lines.extend(["", "## Complete raw output", "```", raw.rstrip(), "```"])
        else:
            lines.extend(
                [
                    "",
                    "## Complete raw output",
                    f"Output is {len(raw)} characters; use `{stdout_path}`.",
                ]
            )
    report = {
        "markdown": "\n".join(lines),
        "summary_line": summary,
        "reachable": list(parent.get("reachable_hosts") or []),
        "unreachable": [],
        "excluded": list(parent.get("excluded_hosts") or []),
        "exec_ok": hosts if status != "failed" else [],
        "exec_fail": hosts if status == "failed" else [],
        "monitor_backend": "mpi-monitor",
        "monitor_run_id": run_id,
        "monitor_meta_path": str(run_dir / "meta.json"),
        "monitor_series_count": len(series),
    }
    return {
        **parent,
        "status": status,
        "phase": "done",
        "summary": summary,
        "monitor_backend": "mpi-monitor",
        "monitor_run_id": run_id,
        "monitor_meta_path": str(run_dir / "meta.json"),
        "monitor_series_count": len(series),
        "partition_report": report,
    }


def run(args: argparse.Namespace) -> dict[str, Any]:
    job_dir = Path(os.environ["AGENT_JOB_DIR"])
    job_id = os.environ["AGENT_JOB_ID"]
    parent = _load_parent_job(job_dir, job_id)
    hosts = _select_hosts(parent, args.hosts, args.host_count)
    agent_root = Path(__file__).resolve().parents[2]
    monitor, env = _mpi_monitor_argv(agent_root)
    probe = subprocess.run(
        [*monitor, "probe"], capture_output=True, text=True, timeout=10, env=env
    )
    if probe.returncode != 0:
        raise RuntimeError((probe.stderr or probe.stdout or "mpi-monitor probe failed").strip())

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
    output_root = job_dir / "mpi-monitor" / job_id
    run_dir = output_root / run_id
    stdout_path = job_dir / f"{job_id}.program.stdout"
    stderr_path = job_dir / f"{job_id}.monitor.stderr"
    mpirun = os.environ.get("MPIRUN") or "/usr/bin/mpirun"
    ranks = len(hosts) * args.ranks_per_node
    command = [
        mpirun,
        "-np",
        str(ranks),
        "-ppn",
        str(args.ranks_per_node),
        "-hosts",
        ",".join(hosts),
        "-wdir",
        "/tmp",
        args.executable,
    ]
    wrap_argv = [
        *monitor,
        "wrap",
        "--hosts",
        ",".join(hosts),
        "--match",
        Path(args.executable).name,
        "--output-dir",
        str(output_root),
        "--interval",
        str(args.interval),
        "--join-timeout",
        str(args.join_timeout),
        "--run-id",
        run_id,
        "--plot" if args.plot else "--no-plot",
        "--",
        *command,
    ]
    append_event(
        job_dir,
        job_id,
        "wrap",
        state="started",
        source="mpi_monitor_workflow",
        run_id=run_id,
        hosts=hosts,
    )
    completed = subprocess.run(
        wrap_argv,
        capture_output=True,
        text=True,
        timeout=args.timeout,
        env=env,
    )
    stdout_path.write_text(completed.stdout or "", encoding="utf-8")
    stderr_path.write_text(completed.stderr or "", encoding="utf-8")
    append_event(
        job_dir,
        job_id,
        "wrap",
        state="completed",
        source="mpi_monitor_workflow",
        run_id=run_id,
        exit_code=completed.returncode,
    )
    meta_path = run_dir / "meta.json"
    if not meta_path.is_file():
        raise RuntimeError(f"mpi-monitor did not write {meta_path}")
    meta = json.loads(meta_path.read_text())
    series = _series_summary(run_dir / "series")
    charts = sorted((run_dir / "charts").glob("*.png"))
    expected_series = ranks
    collection_complete = (
        meta.get("collection_status") == "complete"
        and not meta.get("collect_errors")
        and len(series) >= expected_series
        and (not args.plot or len(charts) >= len(series) * 4)
    )
    app_exit = int(meta.get("application_exit_code", meta.get("exit_code", completed.returncode)))
    if app_exit != 0:
        status = "failed"
    elif collection_complete:
        status = "done"
    else:
        status = "partial"
    summary = (
        f"{status}: mpi-monitor ran {ranks} ranks on {','.join(hosts)}; "
        f"application_exit={app_exit}, series={len(series)}, charts={len(charts)}"
    )
    result = _report(
        parent,
        status=status,
        summary=summary,
        hosts=hosts,
        command=command,
        run_id=run_id,
        run_dir=run_dir,
        meta=meta,
        series=series,
        charts=charts,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        include_raw=args.raw_output,
    )
    append_event(
        job_dir,
        job_id,
        "report",
        state="completed",
        source="mpi_monitor_workflow",
        status=status,
    )
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--partition", required=True)
    parser.add_argument("--hosts", default="")
    parser.add_argument("--host-count", type=int, default=2)
    parser.add_argument("--ranks-per-node", type=int, default=1)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--interval", type=float, default=0.1)
    parser.add_argument("--join-timeout", type=float, default=15)
    parser.add_argument("--plot", type=_bool, default=True)
    parser.add_argument("--raw-output", type=_bool, default=True)
    parser.add_argument("--timeout", type=int, default=1800)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = run(args)
    except Exception as exc:
        print(f"mpi-monitor workflow failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
