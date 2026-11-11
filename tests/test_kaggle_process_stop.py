from pathlib import Path
import signal
import tempfile
import unittest
from unittest import mock


BOOT = Path(__file__).resolve().parents[1] / "scripts/kaggle/kaggle-qwen-boot.sh"


class ManagedProcessStopTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.proc = self.base / "proc"
        self.proc.mkdir()
        source = BOOT.read_text().split("<<'PROCESS_STOP'\n", 1)[1].split("\nPROCESS_STOP", 1)[0]
        self.namespace = {"__name__": "managed_process_test"}
        exec(compile(source, "managed_process_stop.py", "exec"), self.namespace)
        self.namespace["Path"] = lambda path: self.proc if path == "/proc" else Path(path)
        self.stop = self.namespace["stop_managed"]

    def process(self, kind, args, host="127.0.0.1:11434"):
        marker = self.base / ("ollama-serve.pid" if kind == "ollama" else "ollama-stream-proxy.pid")
        marker.write_text("123")
        process = self.proc / "123"
        process.mkdir()
        cmdline = process / "cmdline"
        cmdline.write_bytes(b"\0".join(str(arg).encode() for arg in args) + b"\0")
        (process / "environ").write_bytes(b"OLLAMA_HOST=" + host.encode() + b"\0")
        return marker, cmdline

    def test_only_stops_ollama_server_with_expected_bind_address(self):
        marker, cmdline = self.process("ollama", ["/usr/local/bin/ollama", "serve"])
        with mock.patch("os.kill", side_effect=lambda *_: cmdline.unlink()) as kill:
            self.stop(self.base, "ollama", "127.0.0.1:11434")
        kill.assert_called_once_with(123, signal.SIGTERM)
        self.assertFalse(marker.exists())

    def test_does_not_signal_an_ollama_server_on_another_port(self):
        marker, _ = self.process("ollama", ["ollama", "serve"], host="127.0.0.1:11435")
        with mock.patch("os.kill") as kill:
            self.stop(self.base, "ollama", "127.0.0.1:11434")
        kill.assert_not_called()
        self.assertTrue(marker.exists())

    def test_does_not_signal_a_reused_pid_or_an_ollama_client(self):
        marker, cmdline = self.process("ollama", ["python3", "unrelated.py"])
        for args in (b"python3\0unrelated.py\0", b"ollama\0list\0"):
            cmdline.write_bytes(args)
            with self.subTest(args=args), mock.patch("os.kill") as kill:
                self.stop(self.base, "ollama", "127.0.0.1:11434")
                kill.assert_not_called()
        self.assertTrue(marker.exists())

    def test_zero_and_invalid_pid_cannot_signal_a_process_group(self):
        marker = self.base / "ollama-serve.pid"
        for value in ("0", "-1", "1", "invalid", "99999"):
            marker.write_text(value)
            with self.subTest(value=value), mock.patch("os.kill") as kill:
                self.stop(self.base, "ollama", "127.0.0.1:11434")
                kill.assert_not_called()

    def test_stops_only_the_proxy_script_at_the_expected_path(self):
        marker, cmdline = self.process("proxy", ["python3", "-u", self.base / "ollama-stream-proxy.py"])
        with mock.patch("os.kill", side_effect=lambda *_: cmdline.unlink()) as kill:
            self.stop(self.base, "proxy", "")
        kill.assert_called_once_with(123, signal.SIGTERM)
        self.assertFalse(marker.exists())

    def test_unresponsive_process_keeps_marker_and_blocks_duplicate_start(self):
        marker, _ = self.process("ollama", ["ollama", "serve"])
        with mock.patch("os.kill"), mock.patch("time.sleep"), self.assertRaisesRegex(RuntimeError, "duplicate"):
            self.stop(self.base, "ollama", "127.0.0.1:11434")
        self.assertTrue(marker.exists())


if __name__ == "__main__":
    unittest.main()
