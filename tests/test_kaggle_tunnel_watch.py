import contextlib
import io
from pathlib import Path
import signal
import tempfile
import unittest
from unittest import mock


BOOT = Path(__file__).resolve().parents[1] / "scripts/kaggle/kaggle-qwen-boot.sh"


class StopAfter:
    def __init__(self, checks=100):
        self.remaining = checks
        self.stopped = False
        self.waits = []

    def is_set(self):
        return self.stopped

    def set(self):
        self.stopped = True

    def wait(self, seconds):
        self.waits.append(seconds)
        if self.remaining <= 0:
            self.stopped = True
        self.remaining -= 1
        return self.stopped


class TunnelWatcherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        code = BOOT.read_text().split("<<'TUNNEL_WATCHER'\n", 1)[1].split("\nTUNNEL_WATCHER", 1)[0]
        self.namespace = {"__name__": "watcher_test", "__file__": str(self.base / "cloudflared-watch.py")}
        exec(compile(code, "cloudflared-watch.py", "exec"), self.namespace)
        self.namespace["BASE"] = self.base

    def test_readiness_only_requests_loopback_ready_and_handles_failure(self):
        for status, expected in ((200, True), (503, False)):
            with self.subTest(status=status), mock.patch("http.client.HTTPConnection") as connection:
                connection.return_value.getresponse.return_value.status = status
                self.assertIs(self.namespace["ready"](), expected)
                connection.assert_called_once_with("127.0.0.1", 20241, timeout=2)
                connection.return_value.request.assert_called_once_with("GET", "/ready")
                connection.return_value.close.assert_called_once()
        with mock.patch("http.client.HTTPConnection") as connection:
            connection.return_value.request.side_effect = ConnectionRefusedError()
            self.assertFalse(self.namespace["ready"]())
            connection.return_value.close.assert_called_once()

    def monitor(self, responses, checks=100):
        child = mock.Mock()
        child.poll.return_value = None
        with mock.patch.dict(self.namespace, {"ready": mock.Mock(side_effect=responses)}), contextlib.redirect_stdout(io.StringIO()):
            return self.namespace["monitor"](child, StopAfter(checks))

    def test_brief_disconnect_recovers_without_restarting(self):
        self.assertEqual(self.monitor([True, False, False, True], checks=4), "stopped")

    def test_sustained_disconnect_after_connection_requests_restart(self):
        self.assertEqual(self.monitor([True] + [False] * 6), "readiness failed 6 consecutive checks")

    def test_initial_connection_has_longer_grace_for_native_protocol_fallback(self):
        self.assertEqual(self.monitor([False] * 12), "readiness failed 12 consecutive checks")

    def test_exited_connector_is_detected_without_waiting_for_readiness(self):
        child = mock.Mock()
        child.poll.return_value = 1
        with mock.patch.dict(self.namespace, {"ready": mock.Mock()}) as namespace:
            self.assertEqual(namespace["monitor"](child, StopAfter()), "connector exited")
            namespace["ready"].assert_not_called()

    def test_restarts_existing_tunnel_with_capped_backoff_and_cleans_up(self):
        stopped = StopAfter()
        child = mock.Mock(pid=123)
        calls = []

        def fail_until_stopped(process, event):
            calls.append(process)
            if len(calls) == 8:
                event.set()
            return "connector exited"

        with mock.patch("threading.Event", return_value=stopped), mock.patch("signal.signal"), mock.patch(
            "subprocess.Popen", return_value=child
        ) as spawn, mock.patch("time.monotonic", return_value=0), mock.patch.dict(
            self.namespace, {"monitor": fail_until_stopped, "stop_child": mock.Mock()}
        ), contextlib.redirect_stdout(io.StringIO()):
            self.namespace["watch"]("auto")
        self.assertEqual(stopped.waits, [2, 4, 8, 16, 32, 60, 60])
        self.assertEqual(spawn.call_count, 8)
        for call in spawn.call_args_list:
            self.assertEqual(call.args[0], [
                "cloudflared", "tunnel", "--no-autoupdate", "--metrics", "127.0.0.1:20241",
                "--protocol", "auto", "run",
            ])
        self.assertFalse((self.base / "cloudflared.pid").exists())
        self.assertFalse((self.base / "cloudflared-watch.pid").exists())

    def test_lock_prevents_duplicate_watchers(self):
        with mock.patch("signal.signal"), mock.patch("fcntl.flock", side_effect=BlockingIOError()), mock.patch(
            "subprocess.Popen"
        ) as spawn, contextlib.redirect_stdout(io.StringIO()):
            self.namespace["watch"]("auto")
        spawn.assert_not_called()

    def test_stale_or_invalid_pid_files_never_signal_unrelated_processes(self):
        for value in ("0", "-1", "invalid", "123"):
            with self.subTest(value=value):
                path = self.base / "cloudflared.pid"
                path.write_text(value)
                with mock.patch("os.kill") as kill, mock.patch.dict(self.namespace, {"owned_process": mock.Mock(return_value=False)}):
                    self.namespace["stop_tracked"]("cloudflared.pid", "connector")
                kill.assert_not_called()

    def test_only_owned_process_is_terminated(self):
        (self.base / "cloudflared.pid").write_text("123")
        with mock.patch("os.kill") as kill, mock.patch.dict(self.namespace, {"owned_process": mock.Mock(side_effect=[True, False])}):
            self.namespace["stop_tracked"]("cloudflared.pid", "connector")
        kill.assert_called_once_with(123, signal.SIGTERM)

    def test_connector_identity_requires_the_expected_binary_and_token(self):
        proc = self.base / "proc" / "123"
        proc.mkdir(parents=True)
        (proc / "cmdline").write_bytes(b"/usr/bin/cloudflared\0tunnel\0run\0")
        environment = proc / "environ"
        real_path = Path

        def paths(value):
            return self.base / "proc" if value == "/proc" else real_path(value)

        with mock.patch.dict("os.environ", {"TUNNEL_TOKEN": "expected-token"}), mock.patch.dict(self.namespace, {"Path": paths}):
            environment.write_bytes(b"TUNNEL_TOKEN=other-token\0")
            self.assertFalse(self.namespace["owned_process"](123, "connector"))
            environment.write_bytes(b"TUNNEL_TOKEN=expected-token\0")
            self.assertTrue(self.namespace["owned_process"](123, "connector"))
            (proc / "cmdline").write_bytes(b"python3\0unrelated.py\0")
            self.assertFalse(self.namespace["owned_process"](123, "connector"))

    def test_large_logs_are_bounded(self):
        connector = self.base / "cloudflared.log"
        watcher = self.base / "cloudflared-watch.log"
        connector.write_bytes(b"x" * 17)
        watcher.write_bytes(b"x" * 16)
        self.namespace["MAX_LOG_BYTES"] = 16
        self.namespace["rotate_logs"]()
        self.assertEqual(connector.stat().st_size, 0)
        self.assertEqual(watcher.stat().st_size, 16)

    def test_start_uses_environment_for_credentials_and_waits_for_live_readiness(self):
        daemon = mock.Mock()
        daemon.poll.return_value = None
        token = "test-secret-do-not-persist"
        with mock.patch.dict("os.environ", {"TUNNEL_TOKEN": token}), mock.patch(
            "subprocess.Popen", return_value=daemon
        ) as spawn, mock.patch.dict(self.namespace, {
            "stop_tracked": mock.Mock(), "ready": mock.Mock(return_value=True),
            "read_pid": mock.Mock(return_value=123), "owned_process": mock.Mock(return_value=True),
        }), mock.patch("time.sleep"), contextlib.redirect_stdout(io.StringIO()):
            self.namespace["start"]("http2")
        self.assertEqual(spawn.call_args.kwargs["env"]["TUNNEL_TOKEN"], token)
        self.assertEqual(spawn.call_args.kwargs["env"]["CF_TUNNEL_PROTOCOL"], "http2")
        self.assertNotIn(token, " ".join(spawn.call_args.args[0]))
        for path in self.base.iterdir():
            if path.is_file():
                self.assertNotIn(token, path.read_text())

    def test_start_fails_if_readiness_never_arrives(self):
        daemon = mock.Mock()
        daemon.poll.return_value = None
        with mock.patch("subprocess.Popen", return_value=daemon), mock.patch("time.sleep"), mock.patch.dict(
            self.namespace, {
                "stop_tracked": mock.Mock(), "ready": mock.Mock(return_value=False),
                "read_pid": mock.Mock(return_value=123), "owned_process": mock.Mock(return_value=True),
            }
        ), contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "not ready"):
            self.namespace["start"]("auto")

    def test_start_does_not_accept_an_unrelated_ready_endpoint(self):
        daemon = mock.Mock()
        daemon.poll.return_value = None
        readiness = mock.Mock(return_value=True)
        with mock.patch("subprocess.Popen", return_value=daemon), mock.patch("time.sleep"), mock.patch.dict(
            self.namespace, {
                "stop_tracked": mock.Mock(), "read_pid": mock.Mock(return_value=None), "ready": readiness,
            }
        ), contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "not ready"):
            self.namespace["start"]("auto")
        readiness.assert_not_called()


if __name__ == "__main__":
    unittest.main()
