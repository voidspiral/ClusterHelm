import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / "slave/scripts/workflows/mpi_monitor_workflow.py"


class MpiMonitorWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.job_dir = self.root / "jobs"
        self.job_dir.mkdir()
        self.job_id = "job-parent"
        (self.job_dir / f"{self.job_id}.json").write_text(
            json.dumps(
                {
                    "job_id": self.job_id,
                    "partition": "test",
                    "partition_nodeset": "cn[1-3]",
                    "status": "running",
                    "reachable_hosts": ["cn1", "cn2", "cn3"],
                    "excluded_hosts": [],
                    "nodes": {},
                    "nodestatus_snapshot": {"query_result": "ok"},
                }
            )
        )
        monitor = self.root / "mpi-monitor"
        monitor.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json, pathlib, sys
                if sys.argv[1] == "probe":
                    print("ok")
                    raise SystemExit(0)
                args = sys.argv
                out = pathlib.Path(args[args.index("--output-dir") + 1])
                run_id = args[args.index("--run-id") + 1]
                run = out / run_id
                (run / "series").mkdir(parents=True)
                (run / "charts").mkdir()
                for rank, host in enumerate(("cn1", "cn2")):
                    (run / "series" / f"{host}_pid{rank + 10}.jsonl").write_text(
                        json.dumps({"host": host, "pid": rank + 10, "rank": rank,
                                    "cpu_pct": 20 + rank, "rss_mb": 12,
                                    "io_read_bps": 0, "io_write_bps": 0}) + "\\n"
                    )
                    for metric in ("cpu", "rss", "io_read", "io_write"):
                        (run / "charts" / f"{host}_{metric}.png").write_bytes(b"png")
                (run / "meta.json").write_text(json.dumps({
                    "application_exit_code": 0, "exit_code": 0,
                    "collection_status": "complete", "collect_errors": {}
                }))
                print("NPB Verification SUCCESSFUL")
                """
            )
        )
        monitor.chmod(0o755)
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.root}:{self.env['PATH']}"
        self.env["AGENT_JOB_DIR"] = str(self.job_dir)
        self.env["AGENT_JOB_ID"] = self.job_id
        self.env["MPIRUN"] = "/usr/bin/mpirun"

    def tearDown(self):
        self.tmp.cleanup()

    def test_success_reuses_parent_preflight_and_returns_report(self):
        completed = subprocess.run(
            [
                "python3",
                str(WORKFLOW),
                "--partition",
                "test",
                "--hosts",
                "cn1,cn2",
                "--host-count",
                "2",
                "--ranks-per-node",
                "1",
                "--executable",
                "/opt/npb/is.S.x",
                "--interval",
                "0.1",
                "--join-timeout",
                "15",
                "--plot",
                "true",
                "--raw-output",
                "true",
            ],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=10,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["status"], "done")
        self.assertEqual(result["monitor_series_count"], 2)
        self.assertEqual(result["partition_report"]["exec_ok"], ["cn1", "cn2"])
        self.assertIn(
            "NPB Verification SUCCESSFUL", result["partition_report"]["markdown"]
        )
        events = [
            json.loads(line)
            for line in (
                self.job_dir / f"{self.job_id}.events.jsonl"
            ).read_text().splitlines()
        ]
        self.assertEqual(
            [(row["phase"], row["state"]) for row in events],
            [("wrap", "started"), ("wrap", "completed"), ("report", "completed")],
        )
        self.assertEqual(
            list(self.job_dir.glob("job-*.json")),
            [self.job_dir / f"{self.job_id}.json"],
        )

    def test_unreachable_requested_host_fails_before_probe(self):
        completed = subprocess.run(
            [
                "python3",
                str(WORKFLOW),
                "--partition",
                "test",
                "--hosts",
                "cn1,cn9",
                "--host-count",
                "2",
                "--executable",
                "/opt/npb/is.S.x",
            ],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=10,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("not reachable", completed.stderr)


if __name__ == "__main__":
    unittest.main()
