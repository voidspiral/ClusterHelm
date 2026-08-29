import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
RESOLVE = ROOT / "slave/scripts/resolve-partition.py"
EXEC_SCOPE = ROOT / "slave/scripts/exec_scope.py"
RUN_SLAVE = ROOT / "slave/scripts/run-slave.sh"


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


class ResolvePartitionTests(unittest.TestCase):
    def setUp(self):
        self.resolve = load_module(RESOLVE, "resolve_partition")

    def test_logical_name_keeps_owning_partition(self):
        self.assertEqual("test", self.resolve.owning_partition("test"))
        self.assertEqual("cn[1-3]", self.resolve.resolve("test"))

    def test_host_subset_maps_to_owning_partition(self):
        self.assertEqual("test", self.resolve.owning_partition("cn1"))
        self.assertEqual("test", self.resolve.owning_partition("cn[1-2]"))
        described = self.resolve.describe("cn1")
        self.assertEqual("test", described["partition"])
        self.assertEqual("cn1", described["partition_nodeset"])

    def test_json_cli_prints_owning_partition_and_nodeset(self):
        completed = subprocess.run(
            ["python3", str(RESOLVE), "cn2", "--json"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual("test", payload["partition"])
        self.assertEqual("cn2", payload["partition_nodeset"])


class ExecScopeTests(unittest.TestCase):
    def setUp(self):
        self.scope = load_module(EXEC_SCOPE, "exec_scope")

    def test_auto_uses_gateway_for_mpirun(self):
        self.assertEqual(
            "gateway",
            self.scope.resolve_exec_scope("auto", "mpirun -np 2 /opt/npb/is.S.x"),
        )
        self.assertEqual(
            "nodeset",
            self.scope.resolve_exec_scope("auto", "hostname"),
        )

    def test_explicit_scope_wins(self):
        self.assertEqual(
            "nodeset",
            self.scope.resolve_exec_scope("nodeset", "mpirun -np 2 true"),
        )
        self.assertEqual(
            "gateway",
            self.scope.resolve_exec_scope("gateway", "hostname"),
        )

    def test_gateway_scope_does_not_fan_out_hosts(self):
        self.assertEqual(
            ["cn1"],
            self.scope.exec_hosts("gateway", ["cn1", "cn2", "cn3"], "cn1"),
        )
        self.assertEqual(
            ["cn1", "cn2", "cn3"],
            self.scope.exec_hosts("nodeset", ["cn1", "cn2", "cn3"], "cn1"),
        )


class SubmitExecScopeTests(unittest.TestCase):
    def test_subset_submit_stores_owning_partition_and_scope(self):
        tmp = tempfile.TemporaryDirectory()
        job_dir = Path(tmp.name) / "jobs"
        job_dir.mkdir()
        bin_dir = Path(tmp.name) / "bin"
        bin_dir.mkdir()
        nohup = bin_dir / "nohup"
        nohup.write_text("#!/usr/bin/env bash\nexit 0\n")
        nohup.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env['PATH']}"
        env["AGENT_JOB_DIR"] = str(job_dir)
        completed = subprocess.run(
            [
                "bash",
                str(RUN_SLAVE),
                "submit",
                "--partition",
                "cn1",
                "--command",
                "mpirun -np 2 /opt/npb/is.S.x",
                "--exec-scope",
                "auto",
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        job_id = completed.stdout.strip().split("job_id=", 1)[1].splitlines()[0]
        data = json.loads((job_dir / f"{job_id}.json").read_text())
        self.assertEqual("test", data["partition"])
        self.assertEqual("cn1", data["partition_nodeset"])
        self.assertEqual("gateway", data["exec_scope"])
        tmp.cleanup()


class PreflightOwningPartitionTests(unittest.TestCase):
    def test_legacy_cn1_partition_queries_owning_test(self):
        sys.path.insert(0, str(ROOT / "slave/scripts/preflight"))
        from job_preflight import run_preflight  # noqa: WPS433

        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        calls = root / "nodestatus.argv"
        nodestatus = root / "nodestatus"
        nodestatus.write_text(
            "#!/usr/bin/env python3\n"
            "import json,sys\n"
            "open(%r,'a').write(' '.join(sys.argv[1:])+'\\n')\n"
            "print(json.dumps({'nodes':[{'host':'cn1','state':'online',"
            "'health_state':'online','fresh':True,'last_seen':'2026-08-29T00:00:00Z'}]}))\n"
            % str(calls)
        )
        nodestatus.chmod(0o755)
        job = {
            "job_id": "job-legacy",
            "partition": "cn1",
            "partition_nodeset": "cn1",
            "status": "queued",
            "phase": "queued",
            "nodes": {},
            "failures": [],
        }
        (root / "job-legacy.json").write_text(json.dumps(job))
        env = {
            "NODESTATUS_BIN": str(nodestatus),
            "PATH": f"{root}:{os.environ['PATH']}",
        }
        with mock.patch.dict(os.environ, env):
            result = run_preflight(root, "job-legacy")
        argv = calls.read_text()
        self.assertIn("--partition test", argv)
        self.assertNotIn("--partition cn1", argv)
        self.assertEqual(["cn1"], result["reachable_hosts"])
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
