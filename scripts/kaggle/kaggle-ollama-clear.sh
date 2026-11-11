#!/usr/bin/env bash
set -Eeuo pipefail
set +x

python3 - <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

BASE = Path("/kaggle/working")


def clear_models():
    if not BASE.is_dir():
        raise RuntimeError("Run this inside a Kaggle notebook with /kaggle/working mounted.")

    models = BASE / "ollama_models"
    configured = os.environ.get("OLLAMA_MODELS", "")
    if configured and configured != str(models):
        raise RuntimeError("OLLAMA_MODELS points elsewhere. This script only clears the default Kaggle model directory.")
    if models.is_symlink() or models.is_mount() or (models.exists() and not models.is_dir()):
        raise RuntimeError(f"Refusing to clear a symlink, separate mount, or non-directory: {models}")

    logs = [BASE / name for name in ("ollama.log", "ollama-pull.log", "ollama-serve.pid")]
    for path in logs:
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise RuntimeError(f"Refusing to remove a symlink or non-file: {path}")
    if not all(shutil.which(command) for command in ("pkill", "pgrep")):
        raise RuntimeError("pkill and pgrep are required to stop Ollama before clearing its files.")

    before = shutil.disk_usage(BASE).free
    print(f"Free before: {before / 2**30:.2f} GiB", flush=True)
    print("Stopping Ollama server, runners, and pull clients...", flush=True)
    stopped = subprocess.run(["pkill", "-TERM", "-x", "ollama"], check=False)
    if stopped.returncode not in (0, 1):
        raise RuntimeError("Could not stop Ollama. No model files were removed.")
    for _ in range(30):
        running = subprocess.run(["pgrep", "-x", "ollama"], stdout=subprocess.DEVNULL, check=False)
        if running.returncode == 1:
            break
        if running.returncode != 0:
            raise RuntimeError("Could not verify Ollama stopped. No model files were removed.")
        time.sleep(0.5)
    else:
        raise RuntimeError("Ollama is still running. Cancel other boot/pull cells and retry. No model files were removed.")

    print(f"Removing all saved models and partial downloads from {models}...", flush=True)
    if models.exists():
        shutil.rmtree(models)
    for path in logs:
        path.unlink(missing_ok=True)
    models.mkdir(exist_ok=True)

    after = shutil.disk_usage(BASE).free
    print(f"Free after: {after / 2**30:.2f} GiB; net recovered: {(after - before) / 2**30:.2f} GiB", flush=True)
    print("Model directory cleared. Rerun the boot script with your selected OLLAMA_MODEL.", flush=True)


if __name__ == "__main__":
    try:
        clear_models()
    except (OSError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
PY
