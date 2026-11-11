import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/kaggle/kaggle-ollama-clear.sh"


class ClearModelsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name) / "working"
        self.base.mkdir()
        code = SCRIPT.read_text().split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        self.namespace = {"__name__": "cleanup_test"}
        exec(compile(code, str(SCRIPT), "exec"), self.namespace)
        self.namespace["BASE"] = self.base
        self.environment = mock.patch.dict("os.environ", {"OLLAMA_MODELS": ""})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def clear(self, process_results=None):
        if process_results is None:
            process_results = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1)]
        with mock.patch("shutil.which", return_value="/usr/bin/tool"), mock.patch(
            "subprocess.run", side_effect=process_results
        ) as processes, mock.patch("time.sleep"), contextlib.redirect_stdout(io.StringIO()) as output:
            self.namespace["clear_models"]()
        return processes, output.getvalue()

    def test_clears_models_partials_and_old_logs_preserves_other_notebook_files(self):
        models = self.base / "ollama_models"
        blobs = models / "blobs"
        blobs.mkdir(parents=True)
        for name in ("sha256-old", "sha256-new-partial", "sha256-new-partial-0"):
            (blobs / name).write_text("downloaded weights")
        manifests = models / "manifests"
        manifests.mkdir()
        (manifests / "old-model").write_text("manifest")
        outside = self.base / "notebook-data.txt"
        outside.write_text("keep notebook data")
        (models / "linked-data").symlink_to(outside)
        for name in ("ollama.log", "ollama-pull.log", "ollama-serve.pid"):
            (self.base / name).write_text("old runtime file")
        for name in ("cloudflared.log", "cloudflared.pid"):
            (self.base / name).write_text("keep tunnel state")

        processes, output = self.clear()

        self.assertEqual(list(models.iterdir()), [])
        self.assertEqual(outside.read_text(), "keep notebook data")
        self.assertTrue((self.base / "cloudflared.log").is_file())
        self.assertTrue((self.base / "cloudflared.pid").is_file())
        self.assertFalse((self.base / "ollama-pull.log").exists())
        self.assertEqual(processes.call_args_list[0].args[0], ["pkill", "-TERM", "-x", "ollama"])
        self.assertIn("Free before:", output)
        self.assertIn("net recovered:", output)

    def test_empty_or_missing_model_directory_can_be_cleared_repeatedly(self):
        self.clear([subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 1)])
        self.clear()
        self.assertEqual(list((self.base / "ollama_models").iterdir()), [])

    def test_refuses_symlinked_store_before_stopping_ollama(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep")
        (self.base / "ollama_models").symlink_to(outside, target_is_directory=True)
        with mock.patch("subprocess.run") as processes, self.assertRaisesRegex(RuntimeError, "symlink"):
            self.namespace["clear_models"]()
        processes.assert_not_called()
        self.assertEqual((outside / "keep").read_text(), "keep")

    def test_refuses_log_symlink_before_stopping_ollama(self):
        (self.base / "ollama.log").symlink_to(self.base / "other-file")
        with mock.patch("subprocess.run") as processes, self.assertRaisesRegex(RuntimeError, "symlink"):
            self.namespace["clear_models"]()
        processes.assert_not_called()

    def test_refuses_custom_store_or_non_kaggle_directory(self):
        with mock.patch.dict("os.environ", {"OLLAMA_MODELS": "/other/models"}):
            with self.assertRaisesRegex(RuntimeError, "points elsewhere"):
                self.clear()
        self.namespace["BASE"] = self.base / "missing"
        with self.assertRaisesRegex(RuntimeError, "Kaggle"):
            self.clear()

    def test_preserves_weights_if_ollama_will_not_stop(self):
        models = self.base / "ollama_models"
        models.mkdir()
        (models / "keep").write_text("weights")
        busy = subprocess.CompletedProcess([], 0)
        with self.assertRaisesRegex(RuntimeError, "still running"):
            self.clear([busy] * 31)
        self.assertEqual((models / "keep").read_text(), "weights")

    def test_preserves_weights_when_stop_or_process_check_fails(self):
        models = self.base / "ollama_models"
        models.mkdir()
        (models / "keep").write_text("weights")
        failed = subprocess.CompletedProcess([], 2)
        stopped = subprocess.CompletedProcess([], 0)
        for results in ([failed], [stopped, failed]):
            with self.subTest(results=results), self.assertRaisesRegex(RuntimeError, "No model files were removed"):
                self.clear(results)
            self.assertEqual((models / "keep").read_text(), "weights")


if __name__ == "__main__":
    unittest.main()
