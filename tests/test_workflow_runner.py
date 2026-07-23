import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = ROOT / "slave/scripts/workflows/workflow_runner.py"


def load_runner():
    spec = importlib.util.spec_from_file_location("workflow_runner", RUNNER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


class WorkflowCatalogTests(unittest.TestCase):
    def setUp(self):
        self.runner = load_runner()

    def test_catalog_contains_builtin_workflows(self):
        catalog = self.runner.load_catalog(ROOT / "slave/workflows")
        self.assertEqual(
            {"node-command", "hostname-check", "memory-monitor", "fullcore-mpi"},
            set(catalog),
        )

    def test_unknown_workflow_is_structured_exception(self):
        result = self.runner.run_workflow(
            workflow_id="missing",
            partition="test",
            raw_args=[],
            attempt=1,
            timeout=30,
            agent_root=ROOT / "slave",
        )
        self.assertEqual("exception", result["outcome"])
        self.assertEqual("workflow_missing", result["reason_code"])

    def test_typed_arguments_are_validated(self):
        workflow = self.runner.load_catalog(ROOT / "slave/workflows")["fullcore-mpi"]
        with self.assertRaises(self.runner.ArgumentError):
            self.runner.validate_arguments(
                workflow, ["duration=bad", "interval=2"]
            )
        args = self.runner.validate_arguments(
            workflow, ["duration=60", "interval=2"]
        )
        self.assertEqual({"duration": 60, "interval": 2}, args)

    def test_retry_budget_is_enforced_before_execution(self):
        result = self.runner.run_workflow(
            workflow_id="hostname-check",
            partition="test",
            raw_args=[],
            attempt=3,
            timeout=30,
            agent_root=ROOT / "slave",
        )
        self.assertEqual("exception", result["outcome"])
        self.assertEqual("retry_budget_exceeded", result["reason_code"])

    def test_missing_implementation_is_structured_exception(self):
        with tempfile.TemporaryDirectory() as temp:
            agent_root = Path(temp)
            workflows = agent_root / "workflows"
            workflows.mkdir()
            (workflows / "broken.json").write_text(
                json.dumps(
                    {
                        "id": "broken",
                        "arguments": {},
                        "implementation": {"type": "per-node-command"},
                        "success_policy": {},
                        "max_attempts": 2,
                    }
                )
            )
            result = self.runner.run_workflow(
                workflow_id="broken",
                partition="test",
                raw_args=[],
                attempt=1,
                timeout=30,
                agent_root=agent_root,
            )
        self.assertEqual("exception", result["outcome"])
        self.assertEqual("implementation_missing", result["reason_code"])


class ClassificationTests(unittest.TestCase):
    def setUp(self):
        self.runner = load_runner()
        self.workflow = {
            "id": "x",
            "max_attempts": 2,
            "success_policy": {"allow_exclusion_only_partial": True},
        }

    def test_done_is_success_and_preserves_report(self):
        report = {"markdown": "# deterministic", "exec_fail": []}
        outcome, reason = self.runner.classify_job(
            {"status": "done", "partition_report": report}, self.workflow
        )
        self.assertEqual(("success", "ok"), (outcome, reason))

    def test_exclusion_only_partial_is_success(self):
        outcome, reason = self.runner.classify_job(
            {
                "status": "partial",
                "partition_report": {
                    "markdown": "# deterministic",
                    "exec_fail": [],
                    "excluded": ["cn2"],
                },
            },
            self.workflow,
        )
        self.assertEqual(("success", "ok"), (outcome, reason))

    def test_partial_exec_failure_is_exception(self):
        outcome, reason = self.runner.classify_job(
            {
                "status": "partial",
                "partition_report": {
                    "markdown": "# deterministic",
                    "exec_fail": ["cn2"],
                },
            },
            self.workflow,
        )
        self.assertEqual(("exception", "execution_error"), (outcome, reason))

    def test_missing_report_is_contract_error(self):
        outcome, reason = self.runner.classify_job(
            {"status": "done"}, self.workflow
        )
        self.assertEqual(("exception", "contract_error"), (outcome, reason))


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.runner = load_runner()

    @mock.patch("subprocess.run")
    def test_success_uses_submit_and_single_blocking_wait(self, run):
        job = {
            "job_id": "job-1",
            "status": "done",
            "partition_report": {"markdown": "# deterministic", "exec_fail": []},
        }
        run.side_effect = [
            subprocess.CompletedProcess([], 0, "job_id=job-1\n", ""),
            subprocess.CompletedProcess([], 0, json.dumps(job), ""),
        ]
        result = self.runner.run_workflow(
            workflow_id="hostname-check",
            partition="test",
            raw_args=[],
            attempt=1,
            timeout=30,
            agent_root=ROOT / "slave",
        )
        self.assertEqual("success", result["outcome"])
        self.assertEqual("# deterministic", result["partition_report"]["markdown"])
        self.assertEqual(2, run.call_count)
        self.assertIn("wait", run.call_args_list[1].args[0])

    @mock.patch("subprocess.run")
    def test_timeout_is_structured_and_does_not_drop_context(self, run):
        run.side_effect = subprocess.TimeoutExpired(["run-slave"], 30)
        result = self.runner.run_workflow(
            workflow_id="hostname-check",
            partition="test",
            raw_args=[],
            attempt=1,
            timeout=30,
            agent_root=ROOT / "slave",
        )
        self.assertEqual("exception", result["outcome"])
        self.assertEqual("timeout", result["reason_code"])
        self.assertTrue(result["retry_allowed"])

    @mock.patch("subprocess.run")
    def test_known_failure_preserves_deterministic_report(self, run):
        report = {
            "markdown": "# deterministic failure",
            "exec_fail": ["cn2"],
        }
        job = {
            "job_id": "job-fail",
            "status": "partial",
            "summary": "1/2 ok, 1 failed",
            "partition_report": report,
        }
        run.side_effect = [
            subprocess.CompletedProcess([], 0, "job_id=job-fail\n", ""),
            subprocess.CompletedProcess([], 0, json.dumps(job), ""),
        ]
        result = self.runner.run_workflow(
            workflow_id="hostname-check",
            partition="test",
            raw_args=[],
            attempt=1,
            timeout=30,
            agent_root=ROOT / "slave",
        )
        self.assertEqual("exception", result["outcome"])
        self.assertEqual("execution_error", result["reason_code"])
        self.assertEqual(
            "# deterministic failure", result["partition_report"]["markdown"]
        )
        self.assertTrue(result["retry_allowed"])

    def test_runner_has_no_llm_runtime_call(self):
        self.assertNotIn("opencode", RUNNER_PATH.read_text().lower())


if __name__ == "__main__":
    unittest.main()
