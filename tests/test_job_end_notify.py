import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUN_SLAVE = ROOT / "slave/scripts/run-slave.sh"
POLL_WAIT = ROOT / "master/scripts/poll-wait.sh"
SUBMIT = ROOT / "master/scripts/submit.sh"
MASTER_CONF = ROOT / "master/config/master.conf"
JOB_COMPLETE = ROOT / "slave/scripts/job_complete.py"
JOB_EVENTS = ROOT / "slave/scripts/job_events.py"


def load_job_complete():
    import importlib.util

    spec = importlib.util.spec_from_file_location("job_complete", JOB_COMPLETE)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


def load_job_events():
    import importlib.util

    spec = importlib.util.spec_from_file_location("job_events", JOB_EVENTS)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


def write_job(job_dir: Path, job_id: str, status: str, extra=None):
    data = {
        "job_id": job_id,
        "status": status,
        "phase": "running" if status == "running" else "done",
        "partition": "test",
        "partition_nodeset": "cn[1-3]",
        "deadline_at": (datetime.now(timezone.utc) + timedelta(seconds=1800)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "partition_report": {"markdown": "# ok", "status": status}
        if status in ("done", "partial", "failed")
        else None,
    }
    if extra:
        data.update(extra)
    path = job_dir / f"{job_id}.json"
    path.write_text(json.dumps(data, indent=2))
    return path


CONTRACT = """AGENT_STATUS: done
===PARTITION_REPORT_BEGIN===
# Partition report: test
ok
===PARTITION_REPORT_END===
"""


class JobEventTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.job_dir = Path(self.tmp.name)
        self.events = load_job_events()

    def tearDown(self):
        self.tmp.cleanup()

    def test_append_event_records_structured_monotonic_timeline(self):
        path = self.events.append_event(
            self.job_dir, "job-events", "accepted", state="ok", source="submit"
        )
        self.events.append_event(
            self.job_dir, "job-events", "preflight", state="started"
        )
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        self.assertEqual([row["phase"] for row in rows], ["accepted", "preflight"])
        self.assertEqual(rows[0]["source"], "submit")
        self.assertTrue(all(row["job_id"] == "job-events" for row in rows))
        self.assertLess(rows[0]["monotonic_ns"], rows[1]["monotonic_ns"])
        self.assertTrue(all(row["at"].endswith("Z") for row in rows))

    def test_concurrent_event_writes_are_complete_json_lines(self):
        threads = []
        for worker in range(8):
            thread = threading.Thread(
                target=lambda n=worker: [
                    self.events.append_event(
                        self.job_dir,
                        "job-concurrent",
                        "worker",
                        state="progress",
                        worker=n,
                        index=index,
                    )
                    for index in range(10)
                ]
            )
            threads.append(thread)
            thread.start()
        for thread in threads:
            thread.join()
        path = self.job_dir / "job-concurrent.events.jsonl"
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        self.assertEqual(len(rows), 80)
        self.assertEqual(len({(row["worker"], row["index"]) for row in rows}), 80)
        monotonic = [row["monotonic_ns"] for row in rows]
        self.assertEqual(monotonic, sorted(monotonic))


class WaitSignalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.job_dir = Path(self.tmp.name)
        self.env = os.environ.copy()
        self.env["AGENT_JOB_DIR"] = str(self.job_dir)

    def tearDown(self):
        self.tmp.cleanup()

    def _wait(self, job_id, timeout=8):
        return subprocess.Popen(
            ["bash", str(RUN_SLAVE), "wait", "--job-id", job_id, "--timeout", str(timeout)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.env,
        )

    def test_wait_returns_immediately_when_done_signal_appears(self):
        job_id = "job-signal-ok"
        write_job(self.job_dir, job_id, "running")
        proc = self._wait(job_id, timeout=20)
        time.sleep(0.3)
        write_job(self.job_dir, job_id, "done")
        (self.job_dir / f"{job_id}.done").write_text("done\n")
        t0 = time.monotonic()
        out, err = proc.communicate(timeout=8)
        elapsed = time.monotonic() - t0
        self.assertEqual(proc.returncode, 0, err)
        self.assertEqual(json.loads(out)["status"], "done")
        self.assertLess(
            elapsed,
            2.5,
            f"wait took {elapsed:.2f}s; expected signal wake, not 5s backoff",
        )

    def test_wait_returns_on_failed_terminal_status(self):
        job_id = "job-signal-fail"
        write_job(self.job_dir, job_id, "running")
        proc = self._wait(job_id, timeout=20)
        time.sleep(0.3)
        write_job(self.job_dir, job_id, "failed")
        (self.job_dir / f"{job_id}.done").write_text("failed\n")
        out, err = proc.communicate(timeout=8)
        self.assertEqual(proc.returncode, 0, err)
        self.assertEqual(json.loads(out)["status"], "failed")

    def test_wait_timeout_without_signal(self):
        job_id = "job-hang"
        write_job(self.job_dir, job_id, "running")
        t0 = time.monotonic()
        proc = subprocess.run(
            ["bash", str(RUN_SLAVE), "wait", "--job-id", job_id, "--timeout", "2"],
            capture_output=True,
            text=True,
            env=self.env,
        )
        elapsed = time.monotonic() - t0
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("wait timeout", proc.stderr)
        self.assertIn(job_id, proc.stderr)
        self.assertGreaterEqual(elapsed, 1.5)
        self.assertLess(elapsed, 8)


class JobCompleteHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.job_dir = Path(self.tmp.name)
        self.jc = load_job_complete()

    def tearDown(self):
        self.tmp.cleanup()

    def test_remaining_seconds_does_not_inflate_short_deadline(self):
        deadline = datetime.now(timezone.utc) + timedelta(seconds=30)
        remaining = self.jc.remaining_seconds(deadline)
        self.assertGreaterEqual(remaining, 20)
        self.assertLessEqual(remaining, 30)

    def test_master_wait_timeout_ignores_poll_timeout(self):
        self.assertEqual(self.jc.master_wait_timeout(1800, 30), 1830)
        self.assertNotEqual(self.jc.master_wait_timeout(1800, 30), 15)
        self.assertNotEqual(self.jc.master_wait_timeout(1800, 30), 600)

    def test_finalize_from_contract_kills_running_process(self):
        job_id = "job-early"
        path = write_job(self.job_dir, job_id, "running")
        log_path = self.job_dir / f"{job_id}.agent.log"
        log_path.write_text(CONTRACT)
        proc = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            data = self.jc.finalize_agent_from_log(
                str(path), str(log_path), rc=0, runtime="opencode"
            )
            self.jc.write_done(self.job_dir, job_id, data["status"])
            self.jc.kill_process_group(proc.pid)
            proc.wait(timeout=5)
            self.assertEqual(data["status"], "done")
            self.assertTrue((self.job_dir / f"{job_id}.done").is_file())
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.kill()

    def test_supervise_finalizes_when_contract_appears_while_running(self):
        job_id = "job-watch"
        path = write_job(self.job_dir, job_id, "running")
        log_path = self.job_dir / f"{job_id}.agent.log"
        log_path.write_text("")
        proc = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            def _write_later():
                time.sleep(0.4)
                log_path.write_text(CONTRACT)

            threading.Thread(target=_write_later, daemon=True).start()
            data = self.jc.supervise_agent(
                job_json=str(path),
                log_path=str(log_path),
                pid=proc.pid,
                timeout_sec=15,
                runtime="opencode",
            )
            self.assertEqual(data["status"], "done")
            self.assertTrue((self.job_dir / f"{job_id}.done").is_file())
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.kill()

    def test_supervise_merges_incident_while_still_running(self):
        job_id = "job-incident-merge"
        path = write_job(self.job_dir, job_id, "running")
        log_path = self.job_dir / f"{job_id}.agent.log"
        log_path.write_text("")
        merged = {}
        proc = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:

            def _later():
                time.sleep(0.25)
                incident = {
                    "step": "wrap",
                    "at": "2026-08-25T09:01:00Z",
                    "hosts": ["cn1", "cn2"],
                    "exit_code": 255,
                    "command": ["mpirun", "-np", "2"],
                    "detail_tail": "hydra proxy failed",
                    "source": "mpi-monitor",
                }
                (self.job_dir / f"{job_id}.incident.json").write_text(
                    json.dumps(incident)
                )
                for _ in range(25):
                    time.sleep(0.1)
                    data = json.loads(path.read_text())
                    if data.get("failures"):
                        merged.update(data)
                        break
                log_path.write_text(CONTRACT)

            threading.Thread(target=_later, daemon=True).start()
            data = self.jc.supervise_agent(
                job_json=str(path),
                log_path=str(log_path),
                pid=proc.pid,
                timeout_sec=15,
                runtime="opencode",
                incident_budget_sec=0,
            )
            self.assertEqual(merged.get("status"), "running")
            self.assertIn("wrap", merged.get("summary") or "")
            self.assertEqual(merged["failures"][0]["exit_code"], 255)
            self.assertEqual(merged["agent_progress"]["step"], "wrap")
            self.assertEqual(data["status"], "done")
            self.assertTrue((self.job_dir / f"{job_id}.done").is_file())
        finally:
            if proc.poll() is None:
                proc.kill()

    def test_supervise_finalizes_after_incident_budget(self):
        job_id = "job-incident-budget"
        path = write_job(self.job_dir, job_id, "running")
        log_path = self.job_dir / f"{job_id}.agent.log"
        log_path.write_text("HYDRA unable to start proxy on cn2\n")
        (self.job_dir / f"{job_id}.incident.json").write_text(
            json.dumps(
                {
                    "step": "wrap",
                    "at": "2026-08-25T09:01:00Z",
                    "hosts": ["cn1", "cn2"],
                    "exit_code": 255,
                    "command": ["mpirun", "-np", "2"],
                    "detail_tail": "hydra proxy failed",
                    "source": "mpi-monitor",
                }
            )
        )
        proc = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            t0 = time.monotonic()
            data = self.jc.supervise_agent(
                job_json=str(path),
                log_path=str(log_path),
                pid=proc.pid,
                timeout_sec=15,
                runtime="opencode",
                incident_budget_sec=0.6,
            )
            elapsed = time.monotonic() - t0
            self.assertEqual(data["status"], "failed")
            markdown = data["partition_report"]["markdown"]
            self.assertIn("incident budget exceeded", markdown)
            self.assertIn("hydra proxy failed", markdown)
            self.assertIn("HYDRA unable to start proxy", markdown)
            self.assertLess(elapsed, 5)
            self.assertTrue((self.job_dir / f"{job_id}.done").is_file())
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.kill()


class ScriptFlagsTests(unittest.TestCase):
    def test_opencode_invocation_includes_auto(self):
        src = RUN_SLAVE.read_text()
        self.assertIn("--auto", src)
        self.assertRegex(src, r"run --agent .* --auto")
        self.assertIn("CLUSTERHELM_INCIDENT_PATH", src)
        self.assertIn("AGENT_JOB_ID", src)

    def test_runtime_prompt_routes_process_monitoring_to_mpi_monitor(self):
        src = RUN_SLAVE.read_text()
        normalized = " ".join(src.split())
        self.assertIn("workflow_runner.py run mpi-monitor", normalized)
        self.assertIn(
            "exactly one deterministic workflow",
            normalized,
        )
        self.assertIn(
            "return its partition_report immediately",
            normalized,
        )
        self.assertNotIn("MPI PROCESS-MONITOR INTENT EXCEPTION", src)
        self.assertNotIn("Custom job artifacts and task entrypoints", src)

    def test_poll_wait_timeout_defaults_follow_deadline_not_poll_timeout(self):
        src = POLL_WAIT.read_text()
        self.assertNotIn("TIMEOUT=600", src)
        self.assertNotRegex(src, r"read_master_default poll_timeout")
        self.assertIn("default_deadline", src)
        self.assertIn("wait_slack", src)
        self.assertIn("ServerAliveInterval", src)
        conf = MASTER_CONF.read_text()
        self.assertIn("default_deadline", conf)
        self.assertIn("wait_slack", conf)
        self.assertIn("poll_timeout", conf)

    def test_submit_reads_default_deadline(self):
        src = SUBMIT.read_text()
        self.assertIn("default_deadline", src)


class ScriptWorkerSignalTests(unittest.TestCase):
    def test_worker_writes_done_on_terminal_save_hook(self):
        src = RUN_SLAVE.read_text()
        self.assertIn("job_complete", src)
        self.assertIn("write_done", src)


if __name__ == "__main__":
    unittest.main()
