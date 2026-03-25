#!/usr/bin/env python3
"""Integration tests for the new server.py.
Starts the server in a subprocess, hits each endpoint, checks responses.
"""
import http.client, json, os, re, signal, subprocess, sys, tempfile, time, unittest

PORT = 29999  # avoid clashing with production WEB_PORT


def _start_server(env_overrides):
    env = os.environ.copy()
    env.update(env_overrides)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(os.path.dirname(__file__), "server_new.py")],
        env=env,
    )
    time.sleep(0.8)  # give the server time to bind
    return proc


def _get(path):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    conn.request("GET", path)
    r = conn.getresponse()
    body = r.read().decode()
    conn.close()
    return r.status, r.getheader("Content-Type", ""), body


def _post(path, body=b""):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    conn.request("POST", path, body)
    r = conn.getresponse()
    status = r.status
    resp_body = r.read().decode()
    conn.close()
    return status, resp_body


class TestStatusEndpoint(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, "web-server"), exist_ok=True)
        self.proc = _start_server({
            "WEB_PORT": str(PORT),
            "BORG_MODE": "central",
            "FACILITY_CODE": "testfacility",
            "STATUS_DB_PATH": os.path.join(self.tmp, "web-server", "backup_status.db"),
            "WEB_SERVER_DIR": os.path.join(self.tmp, "web-server"),
            "LOG_DIR": os.path.join(self.tmp, "logs"),
        })

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()

    def test_status_central_mode(self):
        status, ct, body = _get("/api/status")
        self.assertEqual(status, 200)
        self.assertIn("application/json", ct)
        data = json.loads(body)
        self.assertEqual(data["borg_mode"], "central")
        self.assertIsNone(data["drive_mounted"])
        self.assertIsNone(data["repo_ok"])
        self.assertFalse(data["backup_running"])
        self.assertFalse(data["backup_pending"])

    def test_root_returns_html(self):
        status, ct, body = _get("/")
        self.assertEqual(status, 200)
        self.assertIn("text/html", ct)
        self.assertIn("Estado do Backup", body)

    def test_log_invalid_date_returns_400(self):
        status, _, _ = _get("/api/log?date=../../etc/passwd")
        self.assertEqual(status, 400)

    def test_log_missing_date_param_returns_400(self):
        status, _, _ = _get("/api/log")
        self.assertEqual(status, 400)

    def test_log_nonexistent_date_returns_404(self):
        status, _, _ = _get("/api/log?date=19990101")
        self.assertEqual(status, 404)

    def test_trigger_writes_sentinel(self):
        sentinel = os.path.join(self.tmp, "web-server", "trigger_backup")
        self.assertFalse(os.path.exists(sentinel))
        status, _ = _post("/api/trigger-backup")
        self.assertEqual(status, 200)
        self.assertTrue(os.path.exists(sentinel))

    def test_trigger_409_if_sentinel_exists(self):
        sentinel = os.path.join(self.tmp, "web-server", "trigger_backup")
        open(sentinel, "w").close()  # pre-create
        status, _ = _post("/api/trigger-backup")
        self.assertEqual(status, 409)

    def test_status_backup_pending_when_sentinel_exists(self):
        sentinel = os.path.join(self.tmp, "web-server", "trigger_backup")
        open(sentinel, "w").close()
        _, _, body = _get("/api/status")
        data = json.loads(body)
        self.assertTrue(data["backup_pending"])


class TestLogEndpoint(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, "web-server"), exist_ok=True)
        self.log_dir = os.path.join(self.tmp, "logs")
        os.makedirs(self.log_dir, exist_ok=True)
        # write a sample log file
        with open(os.path.join(self.log_dir, "20260324-testfacility-backup.log"), "w") as f:
            f.write("[2026-03-24 14:30:01] - phase=backup state=starting code=1\n")
            f.write("[2026-03-24 14:42:04] - phase=backup state=completed code=2\n")
        self.proc = _start_server({
            "WEB_PORT": str(PORT),
            "BORG_MODE": "central",
            "FACILITY_CODE": "testfacility",
            "STATUS_DB_PATH": os.path.join(self.tmp, "web-server", "backup_status.db"),
            "WEB_SERVER_DIR": os.path.join(self.tmp, "web-server"),
            "LOG_DIR": self.log_dir,
        })

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()

    def test_log_returns_content(self):
        status, ct, body = _get("/api/log?date=20260324")
        self.assertEqual(status, 200)
        self.assertIn("text/plain", ct)
        self.assertIn("phase=backup", body)

    def test_log_valid_date_no_file_returns_404(self):
        status, _, _ = _get("/api/log?date=20200101")
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()
