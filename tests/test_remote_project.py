"""Runtime scripts must read remote_project from master.conf; they must not hardcode a user home."""
from __future__ import annotations

import os
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MASTER_CONF = ROOT / "master/config/master.conf"
SCAN_DIRS = (
    ROOT / "master/scripts",
    ROOT / "scripts",
    ROOT / "slave/scripts",
)
# Former gateway user; must not reappear as a baked-in home.
_OLD_USER = "smt"


def load_master_conf() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in MASTER_CONF.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        parts = line.split(None, 1)
        if len(parts) == 2:
            values[parts[0]] = parts[1]
    return values


def _runtime_files():
    for base in SCAN_DIRS:
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if path.suffix in {".sh", ".py"} and path.is_file():
                yield path


class RemoteProjectHardcodeTests(unittest.TestCase):
    def test_runtime_scripts_do_not_hardcode_old_user_home(self):
        needle = f"/home/{_OLD_USER}/"
        hits = [
            str(path.relative_to(ROOT))
            for path in _runtime_files()
            if needle in path.read_text(errors="replace")
        ]
        self.assertEqual(hits, [], f"hardcoded {needle} in {hits}")

    def test_node_exclude_job_dir_is_relative(self):
        import sys

        preflight = ROOT / "slave/scripts/preflight"
        sys.path.insert(0, str(preflight))
        import node_exclude  # noqa: WPS433

        previous = os.environ.pop("AGENT_JOB_DIR", None)
        try:
            job_dir = node_exclude._job_dir()
        finally:
            if previous is not None:
                os.environ["AGENT_JOB_DIR"] = previous
        remote_project = load_master_conf()["remote_project"]
        self.assertEqual(job_dir.name, "agent-jobs")
        self.assertNotEqual(str(job_dir), f"{remote_project}/var/agent-jobs")
        self.assertTrue(str(job_dir).endswith("slave/var/agent-jobs"))
