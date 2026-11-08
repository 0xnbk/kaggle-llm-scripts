#!/usr/bin/env bash
set -Eeuo pipefail
set +x

MODEL="${OLLAMA_MODEL:-qwen3-coder:30b}"
MODEL_DIR="${OLLAMA_MODELS:-/kaggle/working/ollama_models}"
CONTEXT="${OLLAMA_CONTEXT_LENGTH:-32768}"
BASE="/kaggle/working"
OLLAMA_LOG="$BASE/ollama.log"
CLOUDFLARED_LOG="$BASE/cloudflared.log"
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_MODELS="$MODEL_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ -d "$BASE" ]] || die "Run this inside a Kaggle notebook with /kaggle/working mounted."
command -v nvidia-smi >/dev/null || die "No NVIDIA runtime found. In Kaggle, select a GPU accelerator and restart the session."
nvidia-smi || die "nvidia-smi failed; the GPU runtime is not ready."

if (( EUID == 0 )); then SUDO=(); else command -v sudo >/dev/null || die "Need root or sudo to install packages."; SUDO=(sudo); fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
    echo "Ollama already installed: $(ollama --version)"
    return
  fi

  for attempt in 1 2 3; do
    echo "Installing Ollama (attempt $attempt/3)..."
    if curl -fsSL --retry 3 --retry-all-errors --retry-delay 3 \
      https://ollama.com/install.sh -o "$TMP_DIR/ollama-install.sh" &&
      bash "$TMP_DIR/ollama-install.sh" &&
      command -v ollama >/dev/null && ollama --version >/dev/null 2>&1; then
      echo "Ollama installed."
      return
    fi
    sleep "$((attempt * 3))"
  done

  echo "Ollama's download endpoint failed; trying the official GitHub release..." >&2
  local archive="$TMP_DIR/ollama-linux-amd64.tar.zst"
  curl -fL --retry 6 --retry-all-errors --retry-delay 5 --connect-timeout 30 \
    -o "$archive" \
    https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst ||
    die "Could not download Ollama from either official source. Rerun this script when the network endpoint recovers."
  zstd -t "$archive" >/dev/null || die "The Ollama archive download is incomplete or corrupt."
  "${SUDO[@]}" tar --use-compress-program=unzstd -xf "$archive" -C /usr/local
  "${SUDO[@]}" ln -sf /usr/local/ollama /usr/local/bin/ollama
  command -v ollama >/dev/null && ollama --version >/dev/null 2>&1 || die "Ollama archive extracted but the CLI did not install."
  echo "Ollama installed from the official GitHub release."
}

api_ready() { curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; }
model_installed() { ollama list 2>/dev/null | awk -v m="$MODEL" 'NR > 1 && $1 == m { found=1 } END { exit !found }'; }
install_ollama

if api_ready && ! model_installed; then
  echo "Existing Ollama server does not see $MODEL; restarting it with the persistent model directory."
  pkill -f '[o]llama serve' 2>/dev/null || true
  for _ in {1..15}; do api_ready || break; sleep 1; done
  api_ready && die "Could not stop the existing Ollama server; stopping to avoid pulling the model into the wrong directory."
fi

if ! api_ready; then
  echo "Starting Ollama with model directory $MODEL_DIR and context $CONTEXT..."
  nohup env OLLAMA_MODELS="$MODEL_DIR" OLLAMA_CONTEXT_LENGTH="$CONTEXT" \
    OLLAMA_HOST=127.0.0.1:11434 ollama serve >"$OLLAMA_LOG" 2>&1 </dev/null &
  echo "$!" > "$BASE/ollama-serve.pid"
fi

for _ in {1..90}; do api_ready && break; sleep 1; done
api_ready || { tail -n 40 "$OLLAMA_LOG" 2>/dev/null || true; die "Ollama API did not start; see $OLLAMA_LOG."; }

if ! model_installed; then
  echo "Model $MODEL is not in Ollama's active store; downloading it now (about 18 GB)."
  ollama pull "$MODEL" || die "Model pull failed. Rerun the script; Ollama can resume/reuse downloaded layers."
else
  echo "Found $MODEL in the existing Ollama store; no model download needed."
fi
ollama list

python3 - "$MODEL" <<'PY'
import json, sys, urllib.request

model = sys.argv[1]
payload = json.dumps({
    "model": model,
    "prompt": "Reply with exactly QWEN_OK and nothing else.",
    "stream": False,
    "options": {"temperature": 0},
}).encode()
request = urllib.request.Request(
    "http://127.0.0.1:11434/api/generate",
    data=payload,
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(request, timeout=900) as response:
        answer = json.load(response).get("response", "").strip()
except Exception as exc:
    print(f"ERROR: local Qwen request failed: {exc}", file=sys.stderr)
    sys.exit(1)
if answer != "QWEN_OK":
    print(f"ERROR: model replied {answer!r}, expected 'QWEN_OK'.", file=sys.stderr)
    sys.exit(1)
print("QWEN_OK")
PY

if [[ -n "$TUNNEL_SECRET" ]]; then
  if ! command -v cloudflared >/dev/null; then
    echo "Installing cloudflared..."
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
    if [[ -f "$BASE/cloudflared.pid" ]] && kill -0 "$(cat "$BASE/cloudflared.pid")" 2>/dev/null; then
      echo "Cloudflare Tunnel process is already running."
    else
      export TUNNEL_TOKEN="$TUNNEL_SECRET"
      nohup cloudflared tunnel --no-autoupdate run >"$CLOUDFLARED_LOG" 2>&1 </dev/null &
      tunnel_pid="$!"
      echo "$tunnel_pid" > "$BASE/cloudflared.pid"
      unset TUNNEL_TOKEN
      for _ in {1..20}; do
        grep -qi 'Registered tunnel connection' "$CLOUDFLARED_LOG" 2>/dev/null && break
        kill -0 "$tunnel_pid" 2>/dev/null || break
        sleep 1
      done
      if grep -qi 'Registered tunnel connection' "$CLOUDFLARED_LOG" 2>/dev/null; then
        echo "Cloudflare Tunnel connected: https://llm.retailist.dev"
      else
        echo "Cloudflare Tunnel started but not confirmed connected; inspect $CLOUDFLARED_LOG."
        tail -n 15 "$CLOUDFLARED_LOG" 2>/dev/null || true
      fi
    fi
  else
    echo "Warning: cloudflared is unavailable; local Qwen is working, but the tunnel was skipped." >&2
  fi
  unset TUNNEL_SECRET
fi

echo "GPU status after inference:"
nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader || true
echo "Ollama model status:"
ollama ps || true
