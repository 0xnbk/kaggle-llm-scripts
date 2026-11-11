#!/usr/bin/env bash
set -Eeuo pipefail
set +x

MODEL="${OLLAMA_MODEL:-qwen3.8:27b}"
MODEL_DIR="${OLLAMA_MODELS:-/kaggle/working/ollama_models}"
CONTEXT="${OLLAMA_CONTEXT_LENGTH:-32768}"
BASE="/kaggle/working"
OLLAMA_LOG="$BASE/ollama.log"
export OLLAMA_HOST="127.0.0.1:11435"
export OLLAMA_MODELS="$MODEL_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }
status() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
status "Checking Kaggle GPU and workspace..."
[[ -d "$BASE" ]] || die "Run this inside a Kaggle notebook with /kaggle/working mounted."
command -v nvidia-smi >/dev/null || die "No NVIDIA runtime found. In Kaggle, select a GPU accelerator and restart the session."
nvidia-smi || die "nvidia-smi failed; the GPU runtime is not ready."

if (( EUID == 0 )); then SUDO=(); else command -v sudo >/dev/null || die "Need root or sudo to install packages."; SUDO=(sudo); fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

status "Checking required tools..."
NEED_PACKAGES=()
command -v curl >/dev/null || NEED_PACKAGES+=(curl)
command -v zstd >/dev/null || NEED_PACKAGES+=(zstd)
command -v python3 >/dev/null || NEED_PACKAGES+=(python3)
if ((${#NEED_PACKAGES[@]})); then
  "${SUDO[@]}" apt-get -qq update || echo "Warning: apt update had a repository warning; continuing to install required packages." >&2
  "${SUDO[@]}" apt-get -qq install -y "${NEED_PACKAGES[@]}"
fi
command -v python3 >/dev/null || die "python3 is required for the local API check."
mkdir -p "$MODEL_DIR"

status "Checking Kaggle Cloudflare secret..."
get_tunnel_token() {
  python3 - <<'PY' 2>/dev/null || true
try:
    from kaggle_secrets import UserSecretsClient
    value = UserSecretsClient().get_secret("CF_TUNNEL_TOKEN")
    if value:
        print(value, end="")
except Exception:
    pass
PY
}
TUNNEL_SECRET="${CF_TUNNEL_TOKEN:-}"
unset CF_TUNNEL_TOKEN
if [[ -z "$TUNNEL_SECRET" ]]; then TUNNEL_SECRET="$(get_tunnel_token)"; fi
if [[ -z "$TUNNEL_SECRET" ]]; then
  cat <<'MSG'
Cloudflare Tunnel will be skipped. In Kaggle, open Add-ons > Secrets and add:
  Name: CF_TUNNEL_TOKEN
  Value: the token for your existing Cloudflare Tunnel
Enable notebook access for the secret, then rerun this script.
MSG
fi

install_ollama() {
  if command -v ollama >/dev/null && ollama --version >/dev/null 2>&1; then
    status "Ollama already installed: $(ollama --version)"
    return
  fi

  for attempt in 1 2 3; do
    status "Installing Ollama (attempt $attempt/3)..."
    if curl -fsSL --retry 3 --retry-all-errors --retry-delay 3 \
      https://ollama.com/install.sh -o "$TMP_DIR/ollama-install.sh" &&
      bash "$TMP_DIR/ollama-install.sh" &&
      command -v ollama >/dev/null && ollama --version >/dev/null 2>&1; then
      echo "Ollama installed."
      return
    fi
    sleep "$((attempt * 3))"
  done

  status "Ollama's download endpoint failed; trying the official GitHub release..."
  local archive="$TMP_DIR/ollama-linux-amd64.tar.zst"
  curl -fL --retry 6 --retry-all-errors --retry-delay 5 --connect-timeout 30 --progress-bar \
    -o "$archive" \
    https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst ||
    die "Could not download Ollama from either official source. Rerun this script when the network endpoint recovers."
  zstd -t "$archive" >/dev/null || die "The Ollama archive download is incomplete or corrupt."
  "${SUDO[@]}" tar --use-compress-program=unzstd -xf "$archive" -C /usr/local
  "${SUDO[@]}" ln -sf /usr/local/ollama /usr/local/bin/ollama
  command -v ollama >/dev/null && ollama --version >/dev/null 2>&1 || die "Ollama archive extracted but the CLI did not install."
  status "Ollama installed from the official GitHub release."
}

api_ready() { curl -fsS --max-time 2 http://127.0.0.1:11435/api/version >/dev/null 2>&1; }
legacy_api_ready() { curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; }
proxy_ready() {
  curl -fsS --max-time 2 http://127.0.0.1:11434/_kaggle/stream-proxy/health 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("service")=="ollama-stream-proxy" and d.get("upstream_port")==11435 else 1)' >/dev/null 2>&1
}
stop_managed_process() {
  python3 - "$BASE" "$1" "${2:-}" <<'PROCESS_STOP'
import os
from pathlib import Path
import signal
import sys
import time


def stop_managed(base, kind, expected_host):
    marker = base / ("ollama-serve.pid" if kind == "ollama" else "ollama-stream-proxy.pid")
    try:
        pid = int(marker.read_text().strip())
    except (OSError, ValueError):
        return
    if pid <= 1:
        return

    def matches():
        try:
            process = Path("/proc") / str(pid)
            args = (process / "cmdline").read_bytes().split(b"\0")
            if kind == "proxy":
                return os.fsencode(base / "ollama-stream-proxy.py") in args
            environment = (process / "environ").read_bytes().split(b"\0")
            return (Path(os.fsdecode(args[0])).name == "ollama" and b"serve" in args
                    and b"OLLAMA_HOST=" + os.fsencode(expected_host) in environment)
        except OSError:
            return False

    if not matches():
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    for _ in range(150):
        if not matches():
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("The managed local service did not stop; refusing to start a duplicate.")
    marker.unlink(missing_ok=True)


if __name__ == "__main__":
    stop_managed(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
PROCESS_STOP
}
model_installed() { ollama list 2>/dev/null | awk -v m="$MODEL" 'NR > 1 && $1 == m { found=1 } END { exit !found }'; }
wait_for_api() {
  for second in {1..90}; do
    if api_ready; then status "Ollama API is ready."; return 0; fi
    if ((second % 10 == 0)); then status "Still waiting for Ollama API (${second}s)..."; fi
    sleep 1
  done
  return 1
}

status "Checking Ollama installation..."
install_ollama

status "Checking the local streaming bridge dependencies..."
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || die "The streaming bridge needs Python 3.10 or newer."
PROXY_PACKAGES="$BASE/ollama-proxy-packages"
PROXY_PYTHONPATH="$PROXY_PACKAGES${PYTHONPATH:+:$PYTHONPATH}"
if ! PYTHONPATH="$PROXY_PYTHONPATH" python3 -c 'import aiohttp; assert aiohttp.__version__ == "3.14.5"' >/dev/null 2>&1; then
  python3 -m pip install --disable-pip-version-check --no-cache-dir --upgrade \
    --target "$PROXY_PACKAGES" 'aiohttp==3.14.5' || die "Could not install the isolated streaming bridge dependencies."
fi

PROXY_SCRIPT="$BASE/ollama-stream-proxy.py"
PROXY_SHA256="1e9699fe5f211754ab7c125153677bbce2cd0a58af6730ac27e743f8919b286b"
PROXY_URL="https://raw.githubusercontent.com/0xnbk/kaggle-llm-scripts/f73e4512684089eb315aeb40a0e54a9e71e236ca/scripts/kaggle/ollama-stream-proxy.py"
proxy_source_matches() {
  python3 -c 'import hashlib,pathlib,sys; sys.exit(0 if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()==sys.argv[2] else 1)' "$1" "$PROXY_SHA256" >/dev/null 2>&1
}
if ! proxy_source_matches "$PROXY_SCRIPT"; then
  status "Downloading the pinned streaming bridge..."
  curl -fsSL --retry 3 --retry-all-errors "$PROXY_URL" -o "$TMP_DIR/ollama-stream-proxy.py"
  proxy_source_matches "$TMP_DIR/ollama-stream-proxy.py" || die "Streaming bridge checksum verification failed."
  [[ ! -L "$PROXY_SCRIPT" ]] || die "Refusing to overwrite a symlink at $PROXY_SCRIPT."
  cp "$TMP_DIR/ollama-stream-proxy.py" "$PROXY_SCRIPT"
fi
if legacy_api_ready && ! proxy_ready; then
  status "Moving the managed Ollama server to port 11435 for the streaming bridge..."
  stop_managed_process ollama 127.0.0.1:11434
  for _ in {1..15}; do legacy_api_ready || break; sleep 1; done
  legacy_api_ready && die "Port 11434 is still occupied by an unmanaged service. Stop that service or start a fresh Kaggle session."
fi

if api_ready && ! model_installed; then
  status "Existing server does not see $MODEL; restarting with the persistent model directory."
  stop_managed_process ollama "$OLLAMA_HOST"
  for _ in {1..15}; do api_ready || break; sleep 1; done
  api_ready && die "Could not stop the existing Ollama server; stopping to avoid pulling the model into the wrong directory."
fi

if ! api_ready; then
  status "Starting Ollama with model directory $MODEL_DIR and context $CONTEXT..."
  nohup env OLLAMA_MODELS="$MODEL_DIR" OLLAMA_CONTEXT_LENGTH="$CONTEXT" \
    OLLAMA_HOST=127.0.0.1:11435 ollama serve >"$OLLAMA_LOG" 2>&1 </dev/null &
  echo "$!" > "$BASE/ollama-serve.pid"
fi

wait_for_api || { tail -n 40 "$OLLAMA_LOG" 2>/dev/null || true; die "Ollama API did not start; see $OLLAMA_LOG."; }

if ! model_installed; then
  status "Model $MODEL is missing; pulling it now. Download size depends on the selected model; progress will appear below."
  ollama pull "$MODEL" 2>&1 | tee -a "$BASE/ollama-pull.log" || die "Model pull failed. Rerun to resume downloaded layers. If Ollama reports an unsupported model or architecture, update Ollama and restart its server first."
else
  status "Found $MODEL in the existing Ollama store; no model download needed."
fi
ollama list

python3 - "$MODEL" <<'PY'
import json, sys, threading, time, urllib.request

model = sys.argv[1]
payload = json.dumps({
    "model": model,
    "prompt": "Reply with exactly QWEN_OK and nothing else.",
    "think": False,
    "stream": True,
    "options": {"temperature": 0, "num_predict": 64},
}).encode()
request = urllib.request.Request(
    "http://127.0.0.1:11435/api/generate",
    data=payload,
    headers={"Content-Type": "application/json"},
)
finished = threading.Event()
started = time.monotonic()

def heartbeat():
    while not finished.wait(15):
        elapsed = int(time.monotonic() - started)
        print(f"\n[{elapsed}s] Waiting for Qwen output...", file=sys.stderr, flush=True)

threading.Thread(target=heartbeat, daemon=True).start()
print("Sending Qwen test prompt; streamed output follows:", flush=True)
parts = []
try:
    with urllib.request.urlopen(request, timeout=900) as response:
        for line in response:
            if not line.strip():
                continue
            chunk = json.loads(line)
            if chunk.get("error"):
                raise RuntimeError(chunk["error"])
            text = chunk.get("response", "")
            if text:
                parts.append(text)
                print(text, end="", flush=True)
except Exception as exc:
    finished.set()
    print(f"ERROR: local Qwen request failed: {exc}", file=sys.stderr)
    sys.exit(1)
finally:
    finished.set()
answer = "".join(parts).strip()
print()
if answer != "QWEN_OK":
    print(f"ERROR: model replied {answer!r}, expected 'QWEN_OK'.", file=sys.stderr)
    sys.exit(1)
print("QWEN_OK")
PY

stop_managed_process proxy
proxy_ready && die "The old streaming bridge did not stop; refusing to start a duplicate."
status "Starting streaming bridge on port 11434 with 10-second SSE heartbeats..."
nohup env PYTHONPATH="$PROXY_PYTHONPATH" python3 -u "$PROXY_SCRIPT" \
  --listen-port 11434 --upstream-port 11435 >"$BASE/ollama-stream-proxy.log" 2>&1 </dev/null &
proxy_pid="$!"
echo "$proxy_pid" > "$BASE/ollama-stream-proxy.pid"
for _ in {1..30}; do
  proxy_ready && break
  kill -0 "$proxy_pid" 2>/dev/null || break
  sleep 1
done
if ! kill -0 "$proxy_pid" 2>/dev/null || ! proxy_ready; then
  tail -n 25 "$BASE/ollama-stream-proxy.log" 2>/dev/null || true
  die "Streaming bridge did not start."
fi
status "Streaming bridge ready; silent model/tool-call generation is protected by SSE heartbeats."

if [[ -n "$TUNNEL_SECRET" ]]; then
  if ! command -v cloudflared >/dev/null; then
    status "Installing cloudflared..."
    arch="$(dpkg --print-architecture)"
    curl -fL --retry 5 --retry-all-errors --retry-delay 4 \
      -o "$TMP_DIR/cloudflared.deb" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb" || {
        echo "Warning: cloudflared download failed; local Qwen is working, but the tunnel was skipped." >&2
        unset TUNNEL_SECRET
        exit 0
      }
    if ! "${SUDO[@]}" dpkg -i "$TMP_DIR/cloudflared.deb"; then
      "${SUDO[@]}" apt-get -qq -f install -y || true
    fi
  fi
  if command -v cloudflared >/dev/null; then
    cat > "$BASE/cloudflared-watch.py" <<'TUNNEL_WATCHER'
import fcntl
import http.client
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

BASE = Path("/kaggle/working")
CHECK_INTERVAL = 15
FAILURE_LIMIT = 6
STARTUP_FAILURE_LIMIT = 12
MAX_LOG_BYTES = 5 * 1024 * 1024


def log(message):
    print(time.strftime("[%H:%M:%S] ") + message, flush=True)


def ready():
    connection = http.client.HTTPConnection("127.0.0.1", 20241, timeout=2)
    try:
        connection.request("GET", "/ready")
        return connection.getresponse().status == 200
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def read_pid(path):
    try:
        pid = int(path.read_text().strip())
        return pid if pid > 1 else None
    except (OSError, ValueError):
        return None


def owned_process(pid, kind):
    try:
        args = (Path("/proc") / str(pid) / "cmdline").read_bytes().split(b"\0")
        if kind == "watch":
            return os.fsencode(Path(__file__).resolve()) in args and b"watch" in args
        if Path(os.fsdecode(args[0])).name != "cloudflared" or b"tunnel" not in args or b"run" not in args:
            return False
        environment = (Path("/proc") / str(pid) / "environ").read_bytes().split(b"\0")
        expected = b"TUNNEL_TOKEN=" + os.fsencode(os.environ["TUNNEL_TOKEN"])
        return expected in environment
    except (OSError, KeyError):
        return False


def stop_tracked(filename, kind):
    path = BASE / filename
    pid = read_pid(path)
    if pid and owned_process(pid, kind):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        for _ in range(150):
            if not owned_process(pid, kind):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Previous tunnel process did not stop; refusing to start a duplicate.")
    path.unlink(missing_ok=True)


def stop_child(child):
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def rotate_logs():
    for name in ("cloudflared.log", "cloudflared-watch.log"):
        path = BASE / name
        if path.exists() and path.stat().st_size > MAX_LOG_BYTES:
            with path.open("wb"):
                pass


def monitor(child, stopped):
    failures = 0
    connected = False
    while child.poll() is None:
        if stopped.wait(CHECK_INTERVAL):
            return "stopped"
        rotate_logs()
        if ready():
            connected = True
            if failures:
                log("Tunnel connection recovered.")
            failures = 0
        else:
            failures += 1
            limit = FAILURE_LIMIT if connected else STARTUP_FAILURE_LIMIT
            if failures >= limit:
                return f"readiness failed {failures} consecutive checks"
    return "connector exited"


def watch(protocol):
    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    signal.signal(signal.SIGINT, lambda *_: stopped.set())
    with (BASE / "cloudflared-watch.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("A tunnel watcher is already running.")
            return
        (BASE / "cloudflared-watch.pid").write_text(str(os.getpid()))
        child = None
        backoff = 2
        try:
            while not stopped.is_set():
                rotate_logs()
                with (BASE / "cloudflared.log").open("ab") as output:
                    child = subprocess.Popen(
                        ["cloudflared", "tunnel", "--no-autoupdate", "--metrics", "127.0.0.1:20241",
                         "--protocol", protocol, "run"],
                        stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                    )
                (BASE / "cloudflared.pid").write_text(str(child.pid))
                began = time.monotonic()
                reason = monitor(child, stopped)
                stop_child(child)
                child = None
                (BASE / "cloudflared.pid").unlink(missing_ok=True)
                if stopped.is_set():
                    break
                if time.monotonic() - began >= 300:
                    backoff = 2
                log(f"Restarting existing tunnel: {reason}; retry in {backoff}s.")
                if stopped.wait(backoff):
                    break
                backoff = min(backoff * 2, 60)
        finally:
            if child is not None:
                stop_child(child)
            (BASE / "cloudflared.pid").unlink(missing_ok=True)
            (BASE / "cloudflared-watch.pid").unlink(missing_ok=True)


def start(protocol):
    stop_tracked("cloudflared-watch.pid", "watch")
    stop_tracked("cloudflared.pid", "connector")
    rotate_logs()
    with (BASE / "cloudflared-watch.log").open("ab") as output:
        daemon = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "watch"],
            stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            env={**os.environ, "CF_TUNNEL_PROTOCOL": protocol},
            start_new_session=True,
        )
    healthy_checks = 0
    for second in range(120):
        if daemon.poll() is not None:
            raise RuntimeError("Tunnel watcher stopped. Inspect /kaggle/working/cloudflared-watch.log.")
        pid = read_pid(BASE / "cloudflared.pid")
        connected = pid and owned_process(pid, "connector") and ready()
        healthy_checks = healthy_checks + 1 if connected else 0
        if healthy_checks >= 2:
            log("Cloudflare Tunnel connected; hostname routing is configured in Cloudflare.")
            log("Tunnel watchdog enabled: local readiness checks and automatic connector recovery.")
            return
        if second and second % 15 == 0:
            log(f"Waiting for a live tunnel connection ({second}s)...")
        time.sleep(1)
    raise RuntimeError("Tunnel is not ready. The watcher will keep retrying; inspect cloudflared-watch.log and cloudflared.log.")


if __name__ == "__main__":
    try:
        if not BASE.is_dir() or not os.environ.get("TUNNEL_TOKEN"):
            raise RuntimeError("Kaggle workspace and TUNNEL_TOKEN are required.")
        protocol = os.environ.get("CF_TUNNEL_PROTOCOL", "auto")
        if protocol not in ("auto", "http2", "quic"):
            raise RuntimeError("CF_TUNNEL_PROTOCOL must be auto, http2, or quic.")
        {"start": start, "watch": watch}[sys.argv[1]](protocol)
    except (OSError, RuntimeError, KeyError, IndexError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
TUNNEL_WATCHER
    export TUNNEL_TOKEN="$TUNNEL_SECRET"
    status "Starting supervised Cloudflare Tunnel and checking live readiness..."
    python3 "$BASE/cloudflared-watch.py" start
    unset TUNNEL_TOKEN
  else
    echo "Warning: cloudflared is unavailable; local Qwen is working, but the tunnel was skipped." >&2
  fi
  unset TUNNEL_SECRET
fi

status "GPU status after inference:"
nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader || true
status "Ollama model status:"
ollama ps || true
