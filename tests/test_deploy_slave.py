import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_SLAVE = ROOT / "scripts/deploy/deploy-slave.sh"
MASTER_CONF = ROOT / "master/config/master.conf"
_OLD_USER = "smt"


def load_master_conf() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in MASTER_CONF.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        parts = line.split(None, 1)
        if len(parts) == 2:
            values[parts[0]] = parts[1]
    return values


class DeploySlavePathTests(unittest.TestCase):
    def test_script_does_not_hardcode_old_user_home(self):
        text = DEPLOY_SLAVE.read_text()
        self.assertNotIn(f"/home/{_OLD_USER}/", text)
        self.assertIn("read_master_default remote_project", text)
        self.assertIn("tar -C \"$SLAVE_DIR\"", text)

    def test_print_config_reads_master_conf_remote_project(self):
        remote_project = load_master_conf()["remote_project"]
        out = subprocess.check_output(
            ["bash", str(DEPLOY_SLAVE), "cn1", "--print-config"],
            text=True,
        )
        self.assertIn("gateway=cn1", out)
        self.assertIn(f"remote_project={remote_project}", out)
        self.assertIn(f"remote_job_dir={remote_project}/var/agent-jobs", out)

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
