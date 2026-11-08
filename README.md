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

## Set up a Cloudflare Tunnel with your hostname

Do this once for the Cloudflare hostname and tunnel. The script does not create Cloudflare routes or need to know your hostname: Cloudflare stores the hostname-to-service route, and the script only connects the tunnel from Kaggle. See Cloudflare's [Tunnel setup guide](https://developers.cloudflare.com/tunnel/get-started/) and [Access service token guide](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/).

1. **Make sure your domain is active in Cloudflare.** Use a hostname under a domain listed in your Cloudflare account, such as `llm.example.com`.
2. **Create a service token for your client.** In **Zero Trust → Access controls → Service credentials → Service Tokens**, select **Create Service Token** and save both its Client ID and Client Secret in a secure store on the computer that will run OpenCode or `curl`. Cloudflare only shows the Client Secret once.
3. **Protect the hostname with Access before publishing it.** In **Zero Trust → Access controls → Applications**, create a **Self-hosted** application for the exact hostname. Add a policy with action **Service Auth**, an **Include → Service Token** rule, and select the service token created above. Save the application. Access applications deny requests unless a policy allows them.
4. **Create a remotely managed tunnel** if you do not already have one. In **Networking → Tunnels**, select **Create Tunnel**, choose `cloudflared`, and copy the generated tunnel token. Keep this separate from the Access Client ID and Client Secret.
5. **Add a published application route.** Open the tunnel, select **Routes → Add route → Published application**, enter your hostname, and set **Service URL** to `http://localhost:11434`. Ollama and `cloudflared` run in the same Kaggle session, so `localhost:11434` reaches Ollama. Save the route; Cloudflare creates the DNS route for a domain managed in its zone.
6. **Give Kaggle only the tunnel token.** In the notebook, open **Add-ons → Secrets**, create `CF_TUNNEL_TOKEN`, paste the tunnel token, and grant the notebook access. Do not put the Access Client Secret in the notebook or repository. The Kaggle script reads `CF_TUNNEL_TOKEN` and starts the connector; it does not change the hostname route or Access policy.
7. Run the [quick-start command](#quick-start). When the tunnel reports connected, use `https://<your-hostname>/v1` as the OpenAI-compatible API base URL. Keep the Access Client ID and Client Secret on the client and send them as `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers on API requests.

If you already created the tunnel, route, Access application, and service token, reuse them; just confirm that the route points to `http://localhost:11434` and that the Kaggle secret contains the current tunnel token.

### Verify token-protected streaming

Ollama supports streaming at `/v1/chat/completions`. Send `"stream": true`; for this endpoint Ollama returns Server-Sent Events. Cloudflare Tunnel streams a response as it arrives when the origin responds with `Content-Type: text/event-stream`; otherwise it buffers the response by default. No separate tunnel streaming switch is needed for SSE. See [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility) and [Cloudflare Tunnel streaming troubleshooting](https://developers.cloudflare.com/tunnel/troubleshooting/).

Run this from the machine holding your Access credentials. Set the three environment variables from a secure local secret store first. `--no-buffer` makes `curl` display each event as it arrives.

```bash
: "${API_BASE:?Set API_BASE to https://<your-hostname>/v1}"
: "${CF_ACCESS_CLIENT_ID:?Load the Access Client ID from your secure store}"
: "${CF_ACCESS_CLIENT_SECRET:?Load the Access Client Secret from your secure store}"

curl --no-buffer --include --max-time 180 \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -H "Content-Type: application/json" \
  --data-binary '{
    "model": "qwen3-coder:30b",
    "messages": [{"role": "user", "content": "Count from 1 to 5."}],
    "stream": true
  }' \
  "$API_BASE/chat/completions"
```

The response headers should include `Content-Type: text/event-stream`, followed by `data:` events as Qwen generates them. A `401` or `403` points to the Access application, policy, or client headers. If the answer arrives all at once, check the response `Content-Type` and make sure the client is calling `/v1/chat/completions` with streaming enabled.

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
