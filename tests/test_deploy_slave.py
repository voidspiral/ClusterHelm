import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_SLAVE = ROOT / "scripts/deploy/deploy-slave.sh"


class DeploySlavePathTests(unittest.TestCase):
    def test_script_does_not_hardcode_smt_agents(self):
        text = DEPLOY_SLAVE.read_text()
        self.assertNotIn('REMOTE_PROJECT="/home/smt/agents"', text)
        self.assertIn("read_master_default remote_project", text)
        self.assertIn("tar -C \"$SLAVE_DIR\"", text)

    def test_print_config_reads_master_conf_remote_project(self):
        out = subprocess.check_output(
            ["bash", str(DEPLOY_SLAVE), "cn1", "--print-config"],
            text=True,
        )
        self.assertIn("gateway=cn1", out)
        self.assertIn("remote_project=/home/cn1/agents", out)
        self.assertIn("remote_job_dir=/home/cn1/agents/var/agent-jobs", out)

    def test_remote_project_flag_overrides_conf(self):
        out = subprocess.check_output(
            [
                "bash",
                str(DEPLOY_SLAVE),
                "cn1",
                "--remote-project",
                "/opt/clusterhelm",
                "--print-config",
            ],
            text=True,
        )
        self.assertIn("remote_project=/opt/clusterhelm", out)
        self.assertIn("remote_job_dir=/opt/clusterhelm/var/agent-jobs", out)
