# Kaggle LLM Scripts

Small, versioned setup scripts for model experiments in Kaggle notebooks.

## Scripts

| Script | What it does |
| --- | --- |
| [`kaggle-qwen-boot.sh`](scripts/kaggle/kaggle-qwen-boot.sh) | Checks for an NVIDIA GPU, installs Ollama if needed, reuses or downloads Qwen, starts Ollama, and checks for `QWEN_OK`. It streams timestamped setup progress, model download output, and the Qwen smoke-test response into the notebook cell. If the Kaggle secret exists, it also starts the configured Cloudflare Tunnel. |

Scripts are kept separate from model weights. Qwen files remain in Kaggle's `/kaggle/working/ollama_models` directory when Kaggle file persistence is enabled.

## Quick start

In a Kaggle notebook code cell, run:

```bash
!curl -fsSL https://raw.githubusercontent.com/0xnbk/kaggle-llm-scripts/refs/heads/main/scripts/kaggle/kaggle-qwen-boot.sh | bash
```

This fetches the latest script from `main`. For a fixed, checksum-verified version, use the pinned release instructions below.

## Before using the Kaggle Qwen script

1. Select a GPU accelerator and enable Internet in the notebook settings.
2. Enable file persistence if you want the model files in `/kaggle/working/ollama_models` to carry over between sessions.
3. For the optional tunnel, add a Kaggle Secret named `CF_TUNNEL_TOKEN` under **Add-ons → Secrets**, paste the token for your existing Cloudflare Tunnel, and grant the notebook access to that secret. The script never stores the token in this repository. Without the secret, it prints these instructions and still runs the local Qwen check. The Cloudflare tunnel must already route your chosen hostname to Ollama. The hostname and Access policy are managed in Cloudflare; the script only connects the tunnel.

### Kaggle policy note

Kaggle's [Terms of Use](https://www.kaggle.com/terms) limit use to personal, non-commercial purposes. Its [Acceptable Use Policy](https://www.kaggle.com/aup) prohibits resource abuse, including server farming. This script starts an inference server and can start a Cloudflare Tunnel; Kaggle has not clarified whether a private, self-only setup is allowed. **Check with Kaggle before using its GPU as a remotely reachable inference server.** This repository does not grant permission to use Kaggle resources or bypass its limits.

## Run a versioned release

Use a pinned release, review the script, and verify its checksum before running it. In a Kaggle notebook, use a `%%bash` cell and replace the version if you intentionally choose another release:

```bash
%%bash
set -euo pipefail
VERSION=v0.1.3
BASE="https://github.com/0xnbk/kaggle-llm-scripts/releases/download/$VERSION"
curl -fsSL "$BASE/kaggle-qwen-boot.sh" -o /tmp/kaggle-qwen-boot.sh
curl -fsSL "$BASE/SHA256SUMS" -o /tmp/SHA256SUMS
(cd /tmp && sha256sum --ignore-missing -c SHA256SUMS)
bash /tmp/kaggle-qwen-boot.sh
```

The script uses `/kaggle/working/ollama_models` by default, skips pulling `qwen3-coder:30b` when Ollama already sees it, and prints `QWEN_OK` after a successful local request. Setup stages and model-pull output appear in the cell as they happen. Logs are also written to `/kaggle/working/ollama.log`, `/kaggle/working/ollama-pull.log`, and, if started, `/kaggle/working/cloudflared.log`. Kaggle stops the processes when its session ends; the script does not keep a GPU session alive.

## Release process

Push a version tag such as `v0.2.0`. GitHub Actions checks shell syntax, attaches every script in `scripts/kaggle/` plus `SHA256SUMS`, and publishes a GitHub Release. Published releases are configured to be immutable, so a versioned download stays tied to that release.

To add another script, place it in `scripts/kaggle/`, document it in the table above, then push a new version tag.

## License

This repository is licensed under the [MIT License](LICENSE). Copyright (c) 2026 nbk.dev.
