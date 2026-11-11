# Kaggle LLM Scripts

Small, versioned setup scripts for model experiments in Kaggle notebooks. Run Qwen with Ollama on a Kaggle GPU, then use it from OpenCode on your own computer through an authenticated Cloudflare Tunnel.

## Set up with an AI agent

Copy the prompt below and paste it into your preferred coding agent to get help with setup.

```text
Read https://raw.githubusercontent.com/0xnbk/kaggle-llm-scripts/refs/heads/main/README.md and help set up this project. Inspect existing configuration, follow the documented steps, preserve unrelated settings, handle credentials securely, verify the setup, and report any remaining manual steps.
```

## Available scripts

| Script | What it does |
| --- | --- |
| [`kaggle-qwen-boot.sh`](scripts/kaggle/kaggle-qwen-boot.sh) | Checks for an NVIDIA GPU, installs Ollama if needed, reuses or downloads Qwen, starts Ollama, and checks for `QWEN_OK`. Defaults to `qwen3.8:27b`. It streams setup progress and model output into the notebook. If `CF_TUNNEL_TOKEN` is available, it connects the existing Cloudflare Tunnel with a local readiness watchdog and automatic connector recovery. |
| [`kaggle-ollama-clear.sh`](scripts/kaggle/kaggle-ollama-clear.sh) | Stops Ollama, deletes all saved models and incomplete downloads in `/kaggle/working/ollama_models`, removes the old Ollama logs and server PID file, and reports free space before and after cleanup. |

**Already set up?** Start your Kaggle session, run the script in [Step 5](#5-start-qwen-in-kaggle), then follow [Use OpenCode](#8-use-opencode-for-your-project). To use a different model, follow [Change models](#change-models). For a new setup, follow the steps below in order.

## Contents

- [How the connection works](#how-the-connection-works)
- [Choose a model](#choose-a-model)
- [Change models](#change-models)
- [Known working settings](#known-working-settings)
- [Step-by-step setup](#step-by-step-setup)
- [Troubleshooting](#troubleshooting)
- [Automatic tunnel recovery](#automatic-tunnel-recovery)
- [Clear saved models after a disk-full failure](#clear-saved-models-after-a-disk-full-failure)
- [Run a versioned release](#run-a-versioned-release)
- [Release process](#release-process)

## How the connection works

```mermaid
flowchart LR
    A[OpenCode on your computer] -->|HTTPS and Access credentials| B[Your hostname and Cloudflare Access]
    B -->|Cloudflare Tunnel| C[cloudflared in Kaggle]
    C -->|HTTP to localhost:11434| D[Ollama and Qwen in Kaggle]
```

OpenCode reads your project, edits files, and runs commands on **your computer**. It sends prompts, selected file contents, and tool results to **Qwen in Kaggle** for inference. The project does not need to be uploaded to the notebook as a checkout, but the content sent to the model leaves your computer.

### Why a custom domain is used

This guide uses a **named, remotely managed Cloudflare Tunnel** with a stable hostname such as `llm.example.com`:

- The hostname gives OpenCode a fixed HTTPS API address, even when Kaggle starts a new session.
- Cloudflare Access protects that hostname and checks your client's credentials before forwarding requests.
- `cloudflared` connects outward from Kaggle. You do not need a public Kaggle IP address or an inbound port.

Use a subdomain of a domain you control and have active in Cloudflare. You can reuse an existing domain; a separate domain purchase is unnecessary. A subdomain such as `llm.example.com` can be dedicated to this API without replacing your main website.

**A custom domain is needed for the setup documented here, not for running Qwen inside the notebook.** Cloudflare also offers temporary Quick Tunnels with random `trycloudflare.com` addresses, but those are a different setup and [do not support Server-Sent Events](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/), which this guide uses for streamed model output.

### Addresses and the forwarded Host header

| Setting | Example | Where it belongs |
| --- | --- | --- |
| Public hostname | `llm.example.com` | Cloudflare DNS, the tunnel's published route, and the Access application. |
| Public API base URL | `https://llm.example.com/v1` | OpenCode and client-side API checks. Include `/v1`. |
| Local service URL | `http://localhost:11434` | The tunnel route. This reaches Ollama inside the same Kaggle session as `cloudflared`. |
| HTTP Host Header | `localhost:11434` | The tunnel route's additional HTTP settings. This is the Host header forwarded to Ollama. |

The local service URL uses HTTP because that connection stays inside the Kaggle environment. Your computer connects to the public hostname using HTTPS, and the tunnel connection is encrypted separately.

**The HTTP Host Header setting is required for this loopback-only Ollama setup.** Ollama listens on `127.0.0.1:11434`. If the tunnel forwards the public hostname as the Host header, Ollama can return an empty `403 Forbidden` even after Cloudflare Access accepts your credentials. Setting the forwarded Host header to `localhost:11434` resolves that mismatch. See [Ollama's proxy and tunnel guidance](https://docs.ollama.com/faq#how-can-i-use-ollama-with-cloudflare-tunnel) and [Cloudflare's HTTP Host Header setting](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/#httphostheader).

### Keep the credentials separate

| Credential | What it authorizes | Where to store it |
| --- | --- | --- |
| Cloudflare Tunnel token | Lets `cloudflared` connect the named tunnel to Cloudflare. | Kaggle Secret named `CF_TUNNEL_TOKEN`. |
| Access Client ID and Client Secret | Let OpenCode or `curl` pass the Access policy protecting the API. | A secure store on your computer; load them as `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET`. |
| Cloudflare management API token | Lets an administrator change Cloudflare configuration, according to its permissions. | Only needed if you choose to administer Cloudflare through its API. The notebook and OpenCode do not need it. |

The tunnel token cannot authenticate OpenCode requests. The Access credentials cannot start the tunnel. Keep credentials out of source files, commits, notebook output, and shared logs. Access cookies such as `CF_Authorization` are credentials too.

## Choose a model

The script defaults to **`qwen3.8:27b`**, the official [Ollama model](https://ollama.com/library/qwen3.8:27b). It also accepts other Ollama model IDs and compatible Hugging Face GGUFs through `OLLAMA_MODEL`. Use the [model-switching instructions below](#change-models) to update both Kaggle and OpenCode.

Research checked on **2026-11-10**:

| Model | Why consider it | Evidence limits |
| --- | --- | --- |
| [Official Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) | First baseline for coding, planning, and architecture discussions. The author reports SWE-bench Pro 61.7 and Terminal Bench 2.1 73.0. | Standard post-trained model, not an uncensored release. Vendor results use specific harnesses and settings; they do not establish architecture quality or this notebook's performance. |
| [JonathanColetti Qwen3.8-27B Uncensored](https://huggingface.co/JonathanColetti/Qwen3.8-27B-Uncensored) | First uncensored candidate to compare because its card documents the weight edit, measurements, and limitations. | The author explicitly ran no coding evaluation. Its refusal measurements concern harmful prompts and do not measure refusals of legitimate coding tasks. |
| [Huihui Qwen3.8-27B abliterated](https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF) | Another refusal-reduced Qwen3.8 option, with GGUF downloads. | The repository contains several modified families and quantizations. Select an exact artifact; no comparable coding result was established for the modified model in this review. |
| [Huihui Qwen3-Coder-30B-A3B abliterated](https://huggingface.co/huihui-ai/Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated) | Refusal-reduced derivative of the previous coding model, useful as a comparison. | This link contains Transformers weights; choose a compatible GGUF separately for Ollama. Preserved coding and tool-use quality needs testing. |

These are research candidates, not a measured ranking. Compare them on the same repository tasks: an architecture proposal with tradeoffs, a change across several files with tests, and a tool-use session that includes recovery from a failed command. Evaluate the actual quantization and context you intend to use. "Uncensored" describes reduced refusals; it does not guarantee correct code or complete compliance.

[Qwen3-Coder-Next](https://huggingface.co/Qwen/Qwen3-Coder-Next) is also designed for coding agents, but has **80B total parameters**, despite only 3B being active per token. Four-bit weights alone are roughly 40 GB before overhead, so it is not the first choice for a two-T4 notebook with 32 GB total GPU memory.

## Change models

A model switch has two parts: start the selected model **in Kaggle**, then select the matching model **in OpenCode on your computer**. Reuse your existing authenticated provider and tunnel setup.

### Select and start the model in Kaggle

Choose an exact model ID, including its tag:

| Selection | Value for `OLLAMA_MODEL` |
| --- | --- |
| Official Qwen3.8-27B | `qwen3.8:27b` |
| Previous Qwen3-Coder model, including switching back | `qwen3-coder:30b` |
| Example uncensored Qwen3.8 GGUF | `hf.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF:Q4_K_M` |
| Another model | Its exact Ollama ID, or `hf.co/OWNER/REPOSITORY:QUANTIZATION` for a compatible GGUF. A Transformers/Safetensors repository alone is not an Ollama GGUF download. |

Run this as a **Kaggle notebook cell**. Replace `qwen3.8:27b` with your selection:

```bash
%%bash
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/0xnbk/kaggle-llm-scripts/refs/heads/main/scripts/kaggle/kaggle-qwen-boot.sh -o /tmp/kaggle-qwen-boot.sh
OLLAMA_MODEL='qwen3.8:27b' bash /tmp/kaggle-qwen-boot.sh
ollama list
ollama ps
```

Set `OLLAMA_MODEL` on the **`bash` process**, as shown. Putting it only before `curl` in a pipeline does not pass it to the script. Keep your selection in the cell and rerun it for each session; separate notebook shell cells do not retain shell variable assignments.

The script downloads missing weights, reuses an installed model with the same ID, and checks for `QWEN_OK`. Confirm the model ID in `ollama list` and inspect the loaded model and context in `ollama ps`. The script disables thinking and caps output only for its short check; normal client requests retain their own thinking settings. See [Ollama thinking controls](https://docs.ollama.com/capabilities/thinking).

### Add the matching model to OpenCode on your computer

Open `~/.config/opencode/opencode.json`. Inside your existing `kaggle-qwen` provider, add the selected model to `models`. The provider is under `provider` or `providers`, depending on your OpenCode version; [Step 6](#6-configure-opencode-on-your-computer) shows both formats.

This fragment shows the provider's `models` field for Qwen3.8. Merge the entry with existing models and settings:

```json
{
  "models": {
    "qwen3.8:27b": {
      "name": "Qwen3.8 27B",
      "limit": {
        "context": 32768,
        "output": 8192
      }
    }
  }
}
```

The model **key** must match the ID in Kaggle's `ollama list`; `name` is only a display label. For the uncensored example, use the full `hf.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF:Q4_K_M` as the key. If an existing entry has a `modelID` override, update or remove it so requests use the chosen ID. Keep the previous model entry if you want to select it again later. On schemas with capability fields, declare only the capabilities the selected model and runtime support. See [OpenCode's provider model settings](https://opencode.ai/docs/providers/#models).

Restart OpenCode after editing the configuration. With your Access credentials loaded as in Step 6, run these commands **on your computer**:

```bash
opencode models kaggle-qwen
opencode run -m kaggle-qwen/qwen3.8:27b \
  "Reply with exactly QWEN_OK. Do not use tools."
```

Replace the part after `kaggle-qwen/` with your exact model ID in every command. For example, the uncensored model reference is `kaggle-qwen/hf.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF:Q4_K_M`. A listed model confirms configuration loading; a successful reply verifies inference through the provider. [Step 7](#7-verify-the-public-api-and-opencode) has the public model-list and streaming checks; use the selected model ID in those requests too.

Launch your project session with the same reference:

```bash
opencode -m kaggle-qwen/qwen3.8:27b
```

### Match context limits and check capacity

The `32768` context above matches this repository's current server setting and historical OpenCode 1.19.5 example. The [current Ollama/OpenCode integration guide](https://docs.ollama.com/integrations/opencode) specifies 64K or higher; check your client version's requirements before choosing a context. Larger contexts need separate GPU-memory validation.

To set a different server context, add `OLLAMA_CONTEXT_LENGTH` to the script invocation, for example:

```bash
OLLAMA_MODEL='qwen3.8:27b' OLLAMA_CONTEXT_LENGTH=65536 bash /tmp/kaggle-qwen-boot.sh
```

Run that line in Kaggle after downloading the script. Set the OpenCode model's `limit.context` to the same value and keep its output limit within that context. **Apply server context changes in a fresh Kaggle session**: rerunning the script can reuse an existing Ollama server, whose startup settings stay in effect. Confirm the actual context in `ollama ps` after inference.

Download size is not runtime VRAM; context, runtime buffers, and vision processing add memory. Check `nvidia-smi` after loading. Qwen3.8 and the uncensored variants have not been validated on Kaggle by this repository. `QWEN_OK` verifies a short response; coding quality and tool use need their own checks.

### Switch back and manage retained models

To switch back, rerun the Kaggle cell with `OLLAMA_MODEL='qwen3-coder:30b'`, then select `kaggle-qwen/qwen3-coder:30b` in OpenCode. The same process applies to any previously installed model. Saved weights can be reused if Kaggle persistence retained them.

Switching keeps old model files. Check free disk space before retaining several large downloads. If `ollama ps` shows a previous model still loaded, `ollama stop MODEL_ID` releases that model from memory while keeping its weights. Only use `ollama rm MODEL_ID` when you intend to remove the saved model; using it again will require any missing layers to be downloaded. See the [Ollama CLI reference](https://docs.ollama.com/cli).

If you want to clear the entire default model store, including failed downloads, use [the cleanup script](#clear-saved-models-after-a-disk-full-failure). Switching models alone does not remove the old weights.

If a new model reports an unsupported architecture or version, update Ollama and restart its server before retrying. If OpenCode reports model-not-found, compare its configured key and selected reference with Kaggle's `ollama list`.

## Known working settings

The model and runtime settings below returned `QWEN_OK` through OpenCode on **2026-11-10**, after the HTTP Host Header correction. Public hostname values are examples; use your own domain.

| Setting | Example or tested value |
| --- | --- |
| Public hostname | `llm.example.com` |
| OpenCode API base URL | `https://llm.example.com/v1` |
| Tunnel service URL | `http://localhost:11434` |
| Tunnel HTTP Host Header | `localhost:11434` |
| Access application | Self-hosted application covering `llm.example.com` and all its API paths. |
| Access policy | **Service Auth**, including the client's service token. |
| Ollama bind address | `127.0.0.1:11434` |
| Model | `qwen3-coder:30b` |
| Ollama context length | `32768` tokens, as reported by `ollama ps`. |
| GPU configuration | Two Tesla T4 GPUs; Ollama reported `100% GPU`. |
| OpenCode version | `1.19.5` |
| OpenCode model reference | `kaggle-qwen/qwen3-coder:30b` |
| macOS credential store | Keychain service `kaggle-qwen-cloudflare`, with accounts `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET`. |

All public API hostnames in the examples use `example.com`. Configure your own hostname in Cloudflare and your local client; this repository does not provide a shared inference endpoint.

The successful one-prompt check proves the client-to-model connection. It does not prove repository-scale coding, tool use, or long-session reliability.

This is historical evidence for **Qwen3-Coder**. The current default and setup examples use **Qwen3.8-27B**; its notebook fit, tool use, and OpenCode connection still need runtime validation.

## Step-by-step setup

Expand one step at a time. Start at Step 1 for a new setup, or open the step you need.

<details>
<summary><strong>1. Choose your hostname</strong></summary>

### 1. Choose your hostname

1. Sign in to Cloudflare and confirm that your domain is active in your account.
2. Choose a dedicated hostname, for example `llm.example.com`.
3. Use that exact hostname for the Access application, tunnel route, and OpenCode API base URL throughout this guide.

The hostname and route are configured **in Cloudflare**. The Kaggle script does not create DNS records, choose a hostname, or need an `OLLAMA_PUBLIC_URL` variable. It only connects the tunnel using its token. See the [Cloudflare Tunnel setup guide](https://developers.cloudflare.com/tunnel/get-started/).

</details>

<details>
<summary><strong>2. Create client credentials and protect the hostname</strong></summary>

### 2. Create client credentials and protect the hostname

Set up Access before publishing the route so the API has an authentication policy from the start.

1. Open **Zero Trust → Access controls → Service credentials → Service Tokens**.
2. Select **Create Service Token**, give it a recognizable name, and choose its duration.
3. Save its **Client ID** and **Client Secret** in your computer's secure store. Cloudflare shows the secret only when it is generated. Step 6 includes a macOS Keychain example.
4. Open **Zero Trust → Access controls → Applications** and add a **Self-hosted** application.
5. Set its public hostname to `llm.example.com`. Leave the path unrestricted so the application covers `/v1/*` and `/api/*`.
6. Add an Access policy with action **Service Auth**. Add an **Include → Service Token** rule and select the token you just created.
7. Save the policy and application. Keep this API restricted to the intended service token.

OpenCode sends the Client ID and Client Secret in the `CF-Access-Client-Id` and `CF-Access-Client-Secret` request headers. A browser login alone does not supply these headers to OpenCode. See [Cloudflare Access service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/).

</details>

<details>
<summary><strong>3. Create or reuse a named tunnel</strong></summary>

### 3. Create or reuse a named tunnel

1. In Cloudflare, open **Networking → Tunnels**.
2. Create a tunnel, choose **cloudflared**, and give it a recognizable name. Use a **remotely managed** tunnel for this guide.
3. Copy the generated **tunnel token**. If Cloudflare shows an installation command, copy only the token value for the Kaggle secret.

If you already have the intended tunnel, reuse it and retrieve its current connector token. The script installs and runs `cloudflared` inside Kaggle; you do not need to run Cloudflare's system-service installation command in the notebook.

</details>

<details>
<summary><strong>4. Publish the route and set the HTTP Host Header</strong></summary>

### 4. Publish the route and set the HTTP Host Header

1. Open your tunnel and select **Routes → Add route → Published application**. For an existing route, select **Edit route**.
2. Enter your public hostname, `llm.example.com`.
3. Set **Service URL** to `http://localhost:11434`.
4. Expand **Additional application settings → HTTP settings**.
5. Set **HTTP Host Header** to **`localhost:11434`**. The configuration/API field for this setting is `httpHostHeader`.
6. Save the route. Confirm that Cloudflare has created the proxied DNS record for your hostname pointing to the named tunnel. If a conflicting DNS record already exists, inspect it before replacing anything.

Before moving on, check these values together:

| Cloudflare field | Value |
| --- | --- |
| Published hostname | `llm.example.com` |
| Service URL | `http://localhost:11434` |
| HTTP Host Header | `localhost:11434` |
| Access application hostname | `llm.example.com`, covering all paths. |
| Access policy action | **Service Auth** with your service token included. |

In DNS, the expected record is a **proxied CNAME** from your hostname to `<tunnel-id>.cfargotunnel.com`, using the ID of your named tunnel. Cloudflare normally creates this when you save the published route. `localhost:11434` belongs in the route's service and HTTP Host Header settings, not in the public DNS record.

The **public hostname stays your domain**. Only the Host header on the final request from `cloudflared` to Ollama becomes `localhost:11434`. This setting does not change your DNS name or OpenCode URL. Cloudflare stores it with the route; changing the route does not require downloading the model again. See [updating tunnel origin parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/#update-origin-parameters).

</details>

<details>
<summary><strong>5. Start Qwen in Kaggle</strong></summary>

### 5. Start Qwen in Kaggle

1. Open your Kaggle notebook, select a GPU accelerator, and enable Internet access.
2. Enable file persistence if you want model files in `/kaggle/working/ollama_models` to carry over between sessions. Persistence does not keep processes running when the session ends.
3. Open **Add-ons → Secrets**, create **`CF_TUNNEL_TOKEN`**, and paste the tunnel token from Step 3. Grant the notebook access to this secret.
4. Run this in a notebook code cell:

```bash
!curl -fsSL https://raw.githubusercontent.com/0xnbk/kaggle-llm-scripts/refs/heads/main/scripts/kaggle/kaggle-qwen-boot.sh | bash
```

To select a different model or switch back to an earlier one, use the explicit `OLLAMA_MODEL` command in [Change models](#change-models), then update OpenCode to match.

This quick start fetches the latest script from `main`. For a fixed version that you can review and checksum before execution, use [Run a versioned release](#run-a-versioned-release).

5. Wait for the local model response and tunnel status. The first model load can take several minutes. A successful run includes:

```text
QWEN_OK
Cloudflare Tunnel connected; hostname routing is configured in Cloudflare.
Tunnel watchdog enabled: local readiness checks and automatic connector recovery.
```

The script prints the streamed answer and then a separate success marker, so seeing `QWEN_OK` twice is expected. `Waiting for Qwen output...` is a progress heartbeat while inference is pending.

`QWEN_OK` here proves inference **inside Kaggle**. The tunnel message means the running connector reports an active Cloudflare connection through its local `/ready` endpoint. It does not verify your public DNS, Access policy, forwarded Host header, or OpenCode request. Verify those in Step 7. [Automatic tunnel recovery](#automatic-tunnel-recovery) explains the ongoing checks.

Without `CF_TUNNEL_TOKEN`, the script still runs the local model check and skips the tunnel. Keep Access credentials on your computer; the notebook only needs the tunnel token.

</details>

<details>
<summary><strong>6. Configure OpenCode on your computer</strong></summary>

### 6. Configure OpenCode on your computer

Install OpenCode using its [official installation instructions](https://opencode.ai/docs/), then check your version:

```bash
opencode --version
```

The working setup above uses **OpenCode 1.19.5**. Its configuration uses `provider`, `npm`, and `options`. Newer OpenCode versions use `providers`, `package`, and `settings`; an alternative is included below. Use the format for your installed version.

#### Save the provider configuration

For OpenCode 1.x, add this provider to `~/.config/opencode/opencode.json`. Create the file if it does not exist; otherwise **merge the provider into your existing configuration** so other settings are preserved. Replace `llm.example.com` with your hostname.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "kaggle-qwen": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Kaggle Qwen (Cloudflare Access)",
      "options": {
        "baseURL": "https://llm.example.com/v1",
        "apiKey": "ollama",
        "headers": {
          "CF-Access-Client-Id": "{env:CF_ACCESS_CLIENT_ID}",
          "CF-Access-Client-Secret": "{env:CF_ACCESS_CLIENT_SECRET}"
        }
      },
      "models": {
        "qwen3.8:27b": {
          "name": "Qwen3.8 27B",
          "limit": {
            "context": 32768,
            "output": 8192
          }
        }
      }
    }
  }
}
```

`apiKey: "ollama"` is a non-secret compatibility placeholder. Access authentication comes from the two Cloudflare headers. An OpenAI API key is not needed for this endpoint.

`kaggle-qwen` is the provider's local identifier. Combined with the exact model name, it produces the reference `kaggle-qwen/qwen3.8:27b`. The configuration deliberately leaves your global default model unchanged; the commands below select this model explicitly.

#### Alternative configuration for OpenCode versions using providers/package/settings

This format follows the current [OpenCode provider documentation](https://opencode.ai/docs/providers/) and [V1 migration guide](https://opencode.ai/docs/migrate-v1/). It has not been runtime-tested in the OpenCode 1.19.5 setup above. Use it with a version that supports this schema, and run the same connectivity checks afterward.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "kaggle-qwen": {
      "package": "@opencode/ai/providers/openai-compatible",
      "name": "Kaggle Qwen (Cloudflare Access)",
      "settings": {
        "baseURL": "https://llm.example.com/v1",
        "apiKey": "ollama"
      },
      "headers": {
        "CF-Access-Client-Id": "{env:CF_ACCESS_CLIENT_ID}",
        "CF-Access-Client-Secret": "{env:CF_ACCESS_CLIENT_SECRET}"
      },
      "models": {
        "qwen3.8:27b": {
          "name": "Qwen3.8 27B",
          "capabilities": {
            "tools": true,
            "input": ["text"],
            "output": ["text"]
          },
          "limit": {
            "context": 32768,
            "output": 8192
          }
        }
      }
    }
  }
}
```

#### Load the Access credentials

OpenCode substitutes `{env:CF_ACCESS_CLIENT_ID}` and `{env:CF_ACCESS_CLIENT_SECRET}` from its process environment. On any platform, load those variables from your secure store before starting OpenCode. Having credentials saved in a password manager alone does not make them available to the process.

On **macOS**, you can use Keychain. Save the two values once with the following commands. Each command prompts for its value because `-w` is the last argument; paste the Client ID at the first password prompt and the Client Secret at the second. Do not append a credential to either command.

```bash
security add-generic-password -U -s kaggle-qwen-cloudflare -a CF_ACCESS_CLIENT_ID -w
security add-generic-password -U -s kaggle-qwen-cloudflare -a CF_ACCESS_CLIENT_SECRET -w
```

If these items already exist for your working setup, reuse them. `-U` replaces an existing item's value, so only run the save commands when creating or intentionally updating credentials.

Load them into the Terminal session where you will run the checks and OpenCode:

```bash
export CF_ACCESS_CLIENT_ID="$(security find-generic-password -s kaggle-qwen-cloudflare -a CF_ACCESS_CLIENT_ID -w)"
export CF_ACCESS_CLIENT_SECRET="$(security find-generic-password -s kaggle-qwen-cloudflare -a CF_ACCESS_CLIENT_SECRET -w)"

: "${CF_ACCESS_CLIENT_ID:?Could not load the Access Client ID}"
: "${CF_ACCESS_CLIENT_SECRET:?Could not load the Access Client Secret}"
```

Keep the values out of shell history and avoid printing them. New Terminal sessions need the variables loaded again, or you can use the optional wrapper below. A desktop app launched outside Terminal does not automatically inherit this Terminal environment.

#### Optional macOS zsh wrapper: load Keychain credentials whenever you run opencode

Add this function to `~/.zshrc` if you do not already have an equivalent wrapper. Open a new Terminal window afterward. It uses the OpenCode executable on your `PATH`, passes the credentials only to that command, and forwards all command arguments without forcing a model.

```bash
opencode() {
  local qwen_client_id qwen_client_secret qwen_state_home
  qwen_client_id="$(security find-generic-password -s kaggle-qwen-cloudflare -a CF_ACCESS_CLIENT_ID -w 2>/dev/null)" || {
    echo 'Cloudflare Access client ID is missing from Keychain.' >&2
    return 1
  }
  qwen_client_secret="$(security find-generic-password -s kaggle-qwen-cloudflare -a CF_ACCESS_CLIENT_SECRET -w 2>/dev/null)" || {
    echo 'Cloudflare Access client secret is missing from Keychain.' >&2
    return 1
  }
  qwen_state_home="${XDG_STATE_HOME:-$HOME/.config/opencode/state}"
  mkdir -p "$qwen_state_home" || return 1
  env \
    CF_ACCESS_CLIENT_ID="$qwen_client_id" \
    CF_ACCESS_CLIENT_SECRET="$qwen_client_secret" \
    XDG_STATE_HOME="$qwen_state_home" \
    opencode "$@"
}
```

The tested Mac also needed a writable state directory because the default `~/.local/state/opencode` path returned `EACCES`. This wrapper uses `~/.config/opencode/state` as the state home unless `XDG_STATE_HOME` is already set. It does not require changing ownership of unrelated directories or running OpenCode with `sudo`.

The wrapper loads credentials for **OpenCode only**. Load the exported variables separately when using `curl` in Step 7.

</details>

<details>
<summary><strong>7. Verify the public API and OpenCode</strong></summary>

### 7. Verify the public API and OpenCode

Run these checks on your computer while the Kaggle session is running. Load your Access credentials as described above, then set your public API base URL:

```bash
export API_BASE='https://llm.example.com/v1'

: "${API_BASE:?Set your public API base URL}"
: "${CF_ACCESS_CLIENT_ID:?Load the Access Client ID}"
: "${CF_ACCESS_CLIENT_SECRET:?Load the Access Client Secret}"
```

#### Check the model list

```bash
curl --silent --show-error --fail-with-body --max-time 30 \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -H 'Authorization: Bearer ollama' \
  "$API_BASE/models"
```

Expect HTTP 200 and a JSON response whose `data` array includes `qwen3.8:27b`. This proves the protected route can reach Ollama's model-list endpoint. It does not run inference.

#### Check streamed inference

```bash
curl --no-buffer --silent --show-error --fail-with-body --max-time 300 \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -H 'Authorization: Bearer ollama' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "model": "qwen3.8:27b",
    "messages": [{"role": "user", "content": "Count from 1 to 5."}],
    "stream": true
  }' \
  --write-out '\nHTTP %{http_code}; content type: %{content_type}\n' \
  "$API_BASE/chat/completions"
```

Expect incremental `data:` events, a final `data: [DONE]`, and HTTP 200 with content type `text/event-stream`. The short prompt may finish quickly, so it is primarily a format and connectivity check. `--no-buffer` makes `curl` display events as they arrive; it does not change server buffering.

Ollama's `/v1/chat/completions` supports streaming when `stream` is `true`. Cloudflare Tunnel recognizes the SSE content type for streaming; no separate streaming switch is needed on this route. See [Ollama's OpenAI-compatible API](https://docs.ollama.com/api/openai-compatibility) and [Cloudflare's streaming troubleshooting](https://developers.cloudflare.com/tunnel/troubleshooting/). These commands avoid dumping response cookies; redact credentials and cookies before sharing any diagnostic output.

#### Check OpenCode

```bash
opencode models kaggle-qwen
```

Expect `kaggle-qwen/qwen3.8:27b`. This checks that OpenCode loaded your provider configuration; a listed model alone does not prove the remote API works.

```bash
opencode run -m kaggle-qwen/qwen3.8:27b \
  "Reply with exactly QWEN_OK. Do not use tools."
```

Expect `QWEN_OK` in OpenCode's response. Run this check again after changing models; the historical result above used Qwen3-Coder, not Qwen3.8.

</details>

<details>
<summary><strong>8. Use OpenCode for your project</strong></summary>

### 8. Use OpenCode for your project

Open Terminal in the project you want OpenCode to work on and launch an interactive session:

```bash
cd /path/to/your/project
opencode -m kaggle-qwen/qwen3.8:27b
```

Type tasks normally, for example:

```text
Read this project and explain its structure. Do not change anything yet.
```

```text
Investigate why the login form fails. Explain the cause before editing.
```

```text
Fix the issue in src/example.ts. Preserve unrelated changes and run
the relevant checks afterward.
```

`opencode run ...` sends an individual prompt; `opencode -m ...` opens an ongoing conversation. You can also use `/models` inside OpenCode to select the configured model. Review requested permissions, inspect `git diff`, and run relevant checks before committing model-generated changes.

The tested server has a **32,768-token context window**, shared by instructions, tool definitions, file contents, conversation history, and output. Start with focused tasks and fresh sessions for separate work. [Ollama's current OpenCode guide](https://docs.ollama.com/integrations/opencode) calls for 64k or more for coding use; the 32k example here is only confirmed for the short connectivity check. Increasing the served context requires checking GPU memory and starting Ollama with the new setting. Editing OpenCode's `limit.context` alone does not increase Ollama's capacity. The script can reuse an already-running server, so changing `OLLAMA_CONTEXT_LENGTH` before rerunning it does not necessarily reconfigure that server.

</details>

<details>
<summary><strong>9. Resume later or stop the session</strong></summary>

### 9. Resume later or stop the session

For a later session:

1. Start the Kaggle GPU session and confirm Internet access and secret access.
2. Run the boot script again. It reuses model files when Ollama can see them; if the files were not preserved, it needs to download them again.
3. Keep the existing hostname, route, Access application, and client credentials. A new Kaggle session does not require recreating them.
4. Check `QWEN_OK` and the tunnel connection, then run the OpenCode smoke command if needed.
5. Launch OpenCode from your project directory.

Closing OpenCode does not stop Kaggle. Stop the Kaggle session when finished to release its GPU resources. When Kaggle ends the session, Ollama and `cloudflared` stop and the public endpoint becomes unavailable until a connector is running again. The script does not keep a GPU session alive or bypass Kaggle session limits.

</details>

## Troubleshooting

### Identify which part failed

| Symptom | What to check |
| --- | --- |
| `No space left on device` while writing a model blob or `ollama-pull.log` | The Kaggle disk cannot accept more data. Old model weights and partial downloads can fill the same volume. Inspect disk usage, then [clear saved models](#clear-saved-models-after-a-disk-full-failure) if you want a complete model-store reset. |
| Local `QWEN_OK`, but the public API fails | The local model works. Check public DNS, Access, the published route, and the HTTP Host Header; local inference does not test those. |
| `401`/`403` with an Access error page, or a redirect to login | Check both client headers, token validity, the exact Access hostname, and the **Service Auth** policy's included token. |
| Empty `403`, including after Access accepts credentials | Check **HTTP Host Header = `localhost:11434`** first. Ollama's loopback Host check can reject the public hostname. Do not assume every 403 means invalid Access credentials. |
| Cloudflare `1033`, often shown with HTTP 530 | No healthy connector is available for the named tunnel. Check that the Kaggle session is running, then inspect the [local watchdog and readiness checks](#automatic-tunnel-recovery). A historical connection message does not establish current tunnel health. |
| HTTP 502 | A connector may be reachable while the local origin is not. Check Ollama, port `11434`, and the route's service URL. |
| Hostname does not resolve | Confirm the domain is active and the published route's DNS record exists. |
| Model missing or a model-not-found response | Compare the client model ID with `ollama list` in Kaggle. The default ID includes the tag: `qwen3.8:27b`. |
| OpenCode cannot find the provider, or rejects configuration fields | Check your OpenCode version and the configuration format in Step 6. Merge into the config used by that process, then restart OpenCode. |
| OpenCode works in one Terminal but fails in another or in a desktop app | Check which environment has the Access variables or Keychain wrapper loaded. |
| `EACCES` creating `~/.local/state/opencode` on macOS | Use a writable `XDG_STATE_HOME`, as in the optional wrapper. |
| Initial inference takes minutes or times out | Inspect Ollama's logs and GPU status; a cold model load can be slow. Increasing a client's timeout does not override Cloudflare's own proxy timeout limits. |
| Output arrives all at once | Confirm `/v1/chat/completions`, `stream: true`, `text/event-stream`, and a client that displays events incrementally. A very short answer may complete almost immediately. |

### Automatic tunnel recovery

Cloudflare error `1033` means its network cannot find a healthy connector for the tunnel. It can appear as HTTP `530` in OpenCode even while Kaggle's CPU/GPU display remains visible. See [Cloudflare's explanation](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1033/).

The latest boot script starts a watchdog **inside the current Kaggle session**. It checks `http://127.0.0.1:20241/ready` every 15 seconds. Cloudflare documents `/ready` as returning HTTP 200 when the connector has an active connection to its network. A running PID or an earlier connection log is not used as the readiness check. See [Cloudflare's readiness example](https://developers.cloudflare.com/tunnel/guides/kubernetes/).

If the connector exits, the watchdog restarts it. After an established connection is lost, six consecutive failed checks trigger a restart; the initial connection gets twelve checks to allow native reconnection and protocol fallback. Restart delays increase from 2 seconds to a maximum of 60 seconds. Brief disconnects can recover through `cloudflared` without a restart. The watchdog keeps one managed instance, checks tracked process identity, and stops its child connector when shut down.

**Cloudflare cost:** the watchdog's HTTP checks stay on localhost and reuse the existing tunnel. They create no additional tunnels, users, paid health checks, load balancers, Workers, storage, or scheduled Cloudflare services. No Cloudflare plan or billing settings are changed. Cloudflare currently includes the first 1,000 tunnels per account at no cost; paid additional capacity is a separate purchase. See [Cloudflare's tunnel pricing](https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/#pricing).

To apply the watchdog or manually restart a disconnected connector, rerun the latest boot command. It replaces the tracked tunnel processes and reuses installed model weights:

```bash
%%bash
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/0xnbk/kaggle-llm-scripts/refs/heads/main/scripts/kaggle/kaggle-qwen-boot.sh | OLLAMA_MODEL='qwen3.8:27b' bash
```

Check its current status in another Kaggle cell:

```bash
%%bash
curl --silent --show-error --max-time 3 --output /dev/null \
  --write-out 'Tunnel readiness: HTTP %{http_code}\n' http://127.0.0.1:20241/ready
tail -n 20 /kaggle/working/cloudflared-watch.log
tail -n 20 /kaggle/working/cloudflared.log
```

HTTP 200 confirms the connector currently reports an active connection. The watchdog log records restarts and recovery. Both logs are truncated when they exceed 5 MiB to limit disk growth. The runtime files `cloudflared-watch.py`, `cloudflared-watch.pid`, `cloudflared-watch.lock`, and `cloudflared.pid` live in `/kaggle/working`; the tunnel token is passed in process environments, not written into the watcher file or its command arguments.

The default protocol is `auto`, retaining Cloudflare's native QUIC/HTTP2 fallback. If connector logs show QUIC/UDP timeouts or idle disconnects, you can test TCP by adding `CF_TUNNEL_PROTOCOL=http2` before `bash` in the boot command. TCP port 7844 must be reachable for that option. See [Cloudflare's protocol guidance](https://developers.cloudflare.com/tunnel/troubleshooting/).

The watchdog covers connector failures while it and the Kaggle session remain running. It does not keep a notebook alive, extend GPU quotas, recover a terminated session, or prove that Ollama itself is healthy. After Kaggle ends the session, start a new session and run the boot command again. Older pinned releases such as `v0.1.3` do not include this watchdog.

### Clear saved models after a disk-full failure

A model switch keeps previous weights, so downloading Qwen3.8 can run out of disk space while Qwen3-Coder remains saved. A failed pull can also leave incomplete blobs. `ollama stop` unloads a model from memory; it does not remove saved weights. Lowering the context length does not shrink the downloaded model files.

Inspect the current state in a Kaggle notebook cell:

```bash
%%bash
df -h /kaggle/working
du -sh /kaggle/working/ollama_models
ollama list
```

For a complete reset, **cancel any running boot or model-download cell first**, then run [`kaggle-ollama-clear.sh`](scripts/kaggle/kaggle-ollama-clear.sh). It deletes **all models and incomplete downloads in the default model directory**. It also removes `/kaggle/working/ollama.log`, `ollama-pull.log`, and `ollama-serve.pid`. Other notebook files, Cloudflare tunnel files, and Kaggle Secrets are preserved. Deleted model layers must be downloaded again when needed.

Run this in a new Kaggle notebook cell:

```bash
%%bash
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/0xnbk/kaggle-llm-scripts/refs/heads/main/scripts/kaggle/kaggle-ollama-clear.sh | bash
```

Piping the script to Bash avoids saving another file onto a full disk. If you already copied the cleanup script into the notebook, run `bash /path/to/kaggle-ollama-clear.sh` instead. The script uses Python 3, `pkill`, and `pgrep`; it does not install packages or download model weights.

The cleanup reports free disk space before and after deletion and the net recovered GiB. It stops Ollama before deleting files and refuses to proceed if Ollama remains running. It also refuses symlinked or separately mounted model directories and a custom `OLLAMA_MODELS` value, so it only resets this project's default store.

After cleanup, rerun the boot cell with just the model you want:

```bash
%%bash
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/0xnbk/kaggle-llm-scripts/refs/heads/main/scripts/kaggle/kaggle-qwen-boot.sh | OLLAMA_MODEL='qwen3.8:27b' bash
```

Check the reported free space before retrying. If the disk is still full after the model store is cleared, other notebook files are using the volume; inspect those separately. This script does not reset the entire notebook or guarantee that a selected model fits.

### Confirm the Ollama Host-header mismatch inside Kaggle

If local inference works but authenticated public requests return an empty 403, run this diagnostic in a **new Kaggle notebook cell**:

```bash
%%bash
curl --silent --show-error --max-time 10 --output /dev/null \
  --write-out 'Default local Host: %{http_code}\n' \
  http://127.0.0.1:11434/api/version

curl --silent --show-error --max-time 10 --output /dev/null \
  --write-out 'Public Host: %{http_code}\n' \
  -H 'Host: llm.example.com' \
  http://127.0.0.1:11434/api/version

curl --silent --show-error --max-time 10 --output /dev/null \
  --write-out 'Corrected local Host: %{http_code}\n' \
  -H 'Host: localhost:11434' \
  http://127.0.0.1:11434/api/version
```

Replace `llm.example.com` with your public hostname. Results of `200`, `403`, and `200` reproduce the Host-header restriction directly. Fix the tunnel's **HTTP Host Header** in Step 4, then retry from your computer. Keep Ollama bound to loopback and Access protection enabled.

### Inspect Kaggle logs

Run this in a Kaggle notebook cell:

```bash
%%bash
tail -n 40 /kaggle/working/ollama.log
tail -n 40 /kaggle/working/cloudflared.log
ollama list
ollama ps
nvidia-smi
```

The model pull log is `/kaggle/working/ollama-pull.log` when a download has run. A tunnel log may be absent if the tunnel was skipped. Inspect logs locally and remove credentials, cookies, and private request content before sharing excerpts.

## Kaggle policy note

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
OLLAMA_MODEL=qwen3.8:27b bash /tmp/kaggle-qwen-boot.sh
```

The hostname, Access policy, and HTTP Host Header are Cloudflare configuration and must also be set when using a pinned script release. The example explicitly selects Qwen3.8 because `v0.1.3` predates the new default; its original default is Qwen3-Coder, and it does not include the newer thinking/output limits or tunnel watchdog.

The script uses `/kaggle/working/ollama_models` by default and skips pulling `qwen3.8:27b` when Ollama already sees it. Model weights stay separate from this repository. Kaggle file persistence determines whether those files carry over between sessions.

## Release process

Push a version tag such as `v0.2.0`. GitHub Actions checks shell syntax, attaches every script in `scripts/kaggle/` plus `SHA256SUMS`, and publishes a GitHub Release. Published releases are configured to be immutable, so a versioned download stays tied to that release.

To add another script, place it in `scripts/kaggle/`, document it in the table above, then push a new version tag. A README-only update can be pushed to `main` without publishing a new script release.

## License

This repository is licensed under the [MIT License](LICENSE). Copyright (c) 2026 nbk.dev.
