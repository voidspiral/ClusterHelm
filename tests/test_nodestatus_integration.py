import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PREFLIGHT = ROOT / "slave/scripts/preflight"
sys.path.insert(0, str(PREFLIGHT))
from job_preflight import run_preflight  # noqa: E402
from node_exclude import NodeExclusionStore  # noqa: E402


class PreflightIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls"
        self.nodestatus = self.bin / "nodestatus"
        self.nodestatus.write_text(
            """#!/usr/bin/env python3
import json, os, sys
mode = os.environ.get("FAKE_NODESTATUS", "fresh")
if mode == "fail":
    raise SystemExit(1)
fresh = mode == "fresh" or (mode == "probe-recovers" and "probe" in sys.argv)
print(json.dumps({
  "generated_at": "2026-07-23T08:00:00Z",
  "nodes": [{"host": "cn101", "state": "online", "health_state": "online",
             "fresh": fresh, "last_seen": "2026-07-23T07:59:55Z"}]
}))
"""
        )
        self.nodestatus.chmod(0o755)
        for name in ("ping", "ssh"):
            script = self.bin / name
            script.write_text(
                f"#!/usr/bin/env bash\necho {name} >> \"$FAKE_CALLS\"\nexit 0\n"
            )
            script.chmod(0o755)
        self.job = {
            "job_id": "job-1",
            "partition": "test",
            "partition_nodeset": "cn101",
            "status": "queued",
            "phase": "queued",
            "nodes": {},
            "failures": [],
            "custom_field": {"preserved": True},
        }
        (self.root / "job-1.json").write_text(json.dumps(self.job))
        self.env = {
            "NODESTATUS_BIN": str(self.nodestatus),
            "FAKE_CALLS": str(self.calls),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_fresh_online_status_skips_ping_and_ssh(self):
        with mock.patch.dict(os.environ, {**self.env, "FAKE_NODESTATUS": "fresh"}):
            result = run_preflight(self.root, "job-1")
        self.assertFalse(self.calls.exists())
        self.assertEqual(result["reachable_hosts"], ["cn101"])
        self.assertEqual(result["nodes"]["cn101"]["status_source"], "nodestatus")
        self.assertEqual(result["nodes"]["cn101"]["ping"], "cached")
        self.assertTrue(result["custom_field"]["preserved"])
        self.assertEqual(result["nodestatus_snapshot"]["query_source"], "nodestatus")

    def test_stale_status_runs_legacy_checks(self):
        with mock.patch.dict(os.environ, {**self.env, "FAKE_NODESTATUS": "stale"}):
            result = run_preflight(self.root, "job-1")
        self.assertEqual(self.calls.read_text().splitlines(), ["ping", "ssh"])
        self.assertEqual(result["nodes"]["cn101"]["status_source"], "legacy")

    def test_total_cli_failure_runs_legacy_checks(self):
        with mock.patch.dict(os.environ, {**self.env, "FAKE_NODESTATUS": "fail"}):
            result = run_preflight(self.root, "job-1")
        self.assertEqual(self.calls.read_text().splitlines(), ["ping", "ssh"])
        self.assertNotIn("nodestatus_snapshot", result)

    def test_stale_status_is_refreshed_by_gateway_probe(self):
        with mock.patch.dict(
            os.environ, {**self.env, "FAKE_NODESTATUS": "probe-recovers"}
        ):
            result = run_preflight(self.root, "job-1")
        self.assertFalse(self.calls.exists())
        self.assertEqual(result["nodes"]["cn101"]["status_source"], "nodestatus")
        self.assertEqual(
            result["nodestatus_snapshot"]["query_source"], "nodestatus_probe"
        )

    def test_script_worker_also_reuses_fresh_status(self):
        job = {
            **self.job,
            "command": "true",
            "deadline_at": (
                datetime.now(timezone.utc) + timedelta(minutes=5)
            ).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "reachable_hosts": [],
            "excluded_hosts": [],
            "newly_excluded": [],
        }
        (self.root / "job-1.json").write_text(json.dumps(job))
        env = {
            **os.environ,
            **self.env,
            "FAKE_NODESTATUS": "fresh",
            "AGENT_JOB_DIR": str(self.root),
        }
        subprocess.run(
            [
                "bash",
                str(ROOT / "slave/scripts/run-slave.sh"),
                "_worker",
                "--job-id",
                "job-1",
            ],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(self.calls.read_text().splitlines(), ["ssh"])
        result = json.loads((self.root / "job-1.json").read_text())
        self.assertEqual(result["partition_report"]["query_source"], "nodestatus")
        self.assertIn("markdown", result["partition_report"])

    def test_exclusion_store_keeps_legacy_json_fallback(self):
        legacy = {
            "test": {
                "cn101": {
                    "excluded": True,
                    "reason": "legacy reason",
                    "excluded_since": "2026-07-23T08:00:00Z",
                    "extra": "unchanged",
                }
            }
        }
        (self.root / "node-exclusions.json").write_text(json.dumps(legacy))
        with mock.patch.dict(os.environ, {**self.env, "FAKE_NODESTATUS": "fail"}):
            excluded, entry = NodeExclusionStore(self.root).is_excluded("test", "cn101")
        self.assertTrue(excluded)
        self.assertEqual(entry, legacy["test"]["cn101"])

    def test_daemon_exclusion_is_projected_to_legacy_store(self):
        with mock.patch.dict(os.environ, {**self.env, "FAKE_NODESTATUS": "fresh"}):
            store = NodeExclusionStore(self.root)
            entry = store.exclude(
                "test", "cn101", reason="probe failed", phase="preflight"
            )
        self.assertTrue(entry["excluded"])
        payload = json.loads((self.root / "node-exclusions.json").read_text())
        self.assertEqual(payload["test"]["cn101"]["reason"], "probe failed")


class DeploymentContractTest(unittest.TestCase):
    def test_generated_config_uses_nodestatus_contract(self):
        gateway = (ROOT / "scripts/deploy/deploy-slave.sh").read_text()
        agent = (ROOT / "scripts/deploy/deploy-nodestatus-agents.sh").read_text()
        for key in (
            "socket_path",
            "store_path",
            "exclusion_store_path",
            "heartbeat_timeout",
            "auth_key_file",
        ):
            self.assertIn(key, gateway)
        self.assertIn("gateway_url http://$GATEWAY:", agent)
        self.assertNotIn("/v1/heartbeat", agent)
        self.assertIn("interval 20s", agent)
        self.assertIn("auth_key_file", agent)


class MasterSummaryTest(unittest.TestCase):
    def test_partial_gateway_failure_is_merged(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            conf = root / "slaves.conf"
            conf.write_text("gw1 test cn[1-2]\ngw2 work wn[1-2]\n")
            ssh = root / "ssh"
            ssh.write_text(
                """#!/usr/bin/env python3
import json, sys
gateway = sys.argv[-2]
if gateway == "gw2":
    print("gateway unavailable", file=sys.stderr)
    raise SystemExit(255)
print(json.dumps({"partition": "test", "state_counts": {"online": 2}}))
"""
            )
            ssh.chmod(0o755)
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "master/scripts/nodestatus-summary.py"),
                    "--slaves-conf",
                    str(conf),
                    "--ssh-bin",
                    str(ssh),
                    "--timeout",
                    "1",
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            payload = json.loads(result.stdout)
            self.assertTrue(payload["partial"])
            self.assertIn("test", payload["partitions"])
            self.assertEqual(payload["failures"][0]["partition"], "work")


if __name__ == "__main__":
    unittest.main()
