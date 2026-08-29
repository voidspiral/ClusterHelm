import json
import os
import stat
import subprocess
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "master/scripts/ssh-transport.sh"
SUBMIT = ROOT / "master/scripts/submit.sh"
POLL = ROOT / "master/scripts/poll.sh"
POLL_WAIT = ROOT / "master/scripts/poll-wait.sh"


FAKE_SSH = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    set -euo pipefail
    log="${CLUSTERHELM_SSH_LOG:?}"
    printf '%s\\n' "$*" >> "$log"
    args=" $* "
    if [[ "$args" == *" -O check "* ]]; then
      [[ -f "${CLUSTERHELM_MUX_LIVE:-/}" ]] && exit 0
      exit 1
    fi
    if [[ "$args" == *" -O exit "* ]]; then
      rm -f "${CLUSTERHELM_MUX_LIVE:-}"
      exit 0
    fi
    sleep "${CLUSTERHELM_SSH_SLEEP:-0}"
    if [[ -n "${CLUSTERHELM_SSH_REMOTE_OUT:-}" ]]; then
      printf '%s\\n' "$CLUSTERHELM_SSH_REMOTE_OUT"
    fi
    exit "${CLUSTERHELM_SSH_RC:-0}"
    """
)


class SshTransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.control = self.root / "cm"
        self.log = self.root / "ssh.log"
        self.ssh = self.root / "ssh"
        self.ssh.write_text(FAKE_SSH)
        self.ssh.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{self.root}:{self.env['PATH']}",
                "CLUSTERHELM_SSH_BIN": str(self.ssh),
                "CLUSTERHELM_SSH_CONTROL_DIR": str(self.control),
                "CLUSTERHELM_SSH_COLD_LIMIT": "2",
                "CLUSTERHELM_SSH_CONNECT_TIMEOUT": "15",
                "CLUSTERHELM_SSH_CONTROL_PERSIST": "60",
                "CLUSTERHELM_SSH_LOG": str(self.log),
                "CLUSTERHELM_MUX_LIVE": str(self.root / "mux-live"),
            }
        )

    def tearDown(self):
        self.tmp.cleanup()

    def _run(self, *args, extra_env=None, timeout=10):
        env = dict(self.env)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(HELPER), *args],
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout,
        )

    def test_scripts_source_shared_helper(self):
        for path in (SUBMIT, POLL, POLL_WAIT):
            text = path.read_text()
            self.assertIn("ssh-transport.sh", text, path.name)
            self.assertNotRegex(text, r"\nssh -o ")

    def test_opts_enable_control_master_and_persist(self):
        completed = self._run("print-opts", "cn1")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        opts = completed.stdout
        self.assertIn("ControlMaster=auto", opts)
        self.assertIn("ControlPersist=60", opts)
        self.assertIn(f"ControlPath={self.control}/cn1", opts)
        self.assertIn("BatchMode=yes", opts)
        self.assertIn("ConnectTimeout=15", opts)

    def test_control_dir_is_created_mode_0700(self):
        completed = self._run("prepare", "cn1")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(self.control.is_dir())
        self.assertEqual(stat.S_IMODE(self.control.stat().st_mode), 0o700)

    def test_stale_socket_is_rebuilt_before_connect(self):
        stale = self.control / "cn1"
        self.control.mkdir(mode=0o700)
        stale.write_text("dead")
        completed = self._run("ssh", "cn1", "true")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        log = self.log.read_text()
        self.assertIn("-O check", log)
        self.assertIn("-O exit", log)
        self.assertFalse(stale.exists())

    def test_live_mux_skips_cold_connect_lock(self):
        self.control.mkdir(mode=0o700)
        (self.control / "cn1").write_text("sock")
        (self.root / "mux-live").write_text("1")
        lock = self.control / "cold.cn1.1.lock"
        lock.write_text("")
        holder = open(lock, "a")
        try:
            if not _flock_exclusive(holder.fileno()):
                self.skipTest("flock unavailable")
            completed = self._run("ssh", "cn1", "true")
        finally:
            holder.close()
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_cold_connect_limit_serializes_new_handshakes(self):
        starts = self.root / "starts"
        starts.write_text("")
        extra = {
            "CLUSTERHELM_SSH_COLD_LIMIT": "1",
            "CLUSTERHELM_SSH_SLEEP": "0.35",
        }

        def worker():
            self._run("ssh", "cn1", "true", extra_env=extra)

        t1 = threading.Thread(target=worker)
        t2 = threading.Thread(target=worker)
        began = time.monotonic()
        t1.start()
        t2.start()
        t1.join(timeout=8)
        t2.join(timeout=8)
        elapsed = time.monotonic() - began
        self.assertGreaterEqual(elapsed, 0.6)

    def test_multiplex_failure_falls_back_without_controlmaster(self):
        extra = {"CLUSTERHELM_SSH_RC": "255", "CLUSTERHELM_SSH_REMOTE_OUT": "mux boom"}
        completed = self._run("ssh", "cn1", "true", extra_env=extra)
        self.assertNotEqual(completed.returncode, 0)
        log = self.log.read_text()
        self.assertIn("ControlMaster=no", log)

    def test_submit_follow_waits_on_the_same_remote_session(self):
        fake_out = (
            "job_id=job-follow-1\n"
            "CLUSTERHELM_JOB_JSON\n"
            + json.dumps(
                {
                    "status": "done",
                    "partition_report": {"markdown": "# ok", "status": "done"},
                }
            )
        )
        env = dict(self.env)
        env["CLUSTERHELM_SSH_REMOTE_OUT"] = fake_out
        env["CLUSTERHELM_VAR_ROOT"] = str(self.root)
        completed = subprocess.run(
            [
                "bash",
                str(SUBMIT),
                "--partition",
                "test",
                "--prompt",
                "ping hosts",
                "--gateway",
                "cn1",
                "--follow",
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
            cwd=str(ROOT / "master"),
        )
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        remote = self.log.read_text()
        self.assertIn(" submit ", f" {remote} ")
        self.assertIn(" wait --job-id", remote)
        self.assertIn("job_id=job-follow-1", completed.stdout)
        last = self.root / "agent-jobs" / "job-follow-1.last.json"
        self.assertTrue(last.is_file(), completed.stdout)

    def test_submit_no_follow_does_not_wait(self):
        env = dict(self.env)
        env["CLUSTERHELM_SSH_REMOTE_OUT"] = "job_id=job-async-1"
        env["CLUSTERHELM_VAR_ROOT"] = str(self.root)
        completed = subprocess.run(
            [
                "bash",
                str(SUBMIT),
                "--partition",
                "test",
                "--prompt",
                "ping hosts",
                "--gateway",
                "cn1",
                "--no-follow",
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
            cwd=str(ROOT / "master"),
        )
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        remote = self.log.read_text()
        self.assertIn(" submit ", f" {remote} ")
        self.assertNotIn(" wait --job-id", remote)


def _flock_exclusive(fd: int) -> bool:
    try:
        import fcntl
    except ImportError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


if __name__ == "__main__":
    unittest.main()
