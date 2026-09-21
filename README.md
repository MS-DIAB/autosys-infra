# AutoSys Infra Scripts

Self-hosted Docker infrastructure for a single Linux server: reverse proxy
and TLS, tunneling, container management, log viewing, workflow
automation, and a few self-hosted AI APIs — one script per piece, run in
order to go from a bare VM to a running stack.

## Overview

This repo grew out of running AutoSys, a self-hosted platform, and is
shared here as a reusable starting point for anyone who'd rather own their
infrastructure than rent it piece by piece from SaaS vendors.

Each script handles one layer of the stack and is meant to be read, not
just run — they're commented, they print what they're about to do, and
they stop to ask before anything destructive (like a reboot).

**What's included:**

- **Base host setup** — package updates, timezone, firewall rules, Docker
  Engine
- **Ingress** — Nginx Proxy Manager for reverse proxy + free TLS certs,
  and an optional Cloudflare Tunnel so you never have to open inbound
  ports
- **Ops tooling** — Portainer for container management, Dozzle for live
  log streaming, plus backup/restore scripts for n8n
- **Workflow automation** — n8n, deployed behind the proxy
- **Self-hosted AI** — a local coding LLM (Qwen2.5-Coder via `llama.cpp` +
  Open WebUI) and Arabic-first text-to-speech, translation, and
  speech-to-text APIs

**Who this is for:** developers and sysadmins comfortable reading a bash
script before running it, who want a working reference for wiring these
pieces together rather than a black-box installer. It's shared as-is —
read each script before running it on anything you care about, since they
install packages, open firewall ports, and reboot the host at a few
points.

## Architecture

```
Internet
   │
   ▼
Cloudflare Tunnel
   │
   ▼
Nginx Proxy Manager  (proxy-network, ports 80/443/81)
   │
   ├── n8n            (workflow automation)
   ├── Portainer       (container management UI)
   ├── Dozzle          (live container log viewer)
   ├── Open WebUI      (chat UI for the local LLM)
   ├── TTS API
   ├── Translate API
   ├── STT API
   └── VEJI Decision API
```

Everything runs as Docker containers on a single bridge network
(`proxy-network`) that Nginx Proxy Manager and Cloudflare Tunnel front. The
Qwen2.5-Coder LLM itself runs natively via `llama.cpp` (not in Docker) for
CPU performance, with Open WebUI as its Docker-based chat frontend.

## Prerequisites

- A Rocky Linux / RHEL / CentOS-family host (scripts use `dnf`). Dozzle's
  script also has an `apt-get` fallback for Debian/Ubuntu, but the rest do
  not — port them yourself if you're on a different distro.
- `sudo` access.
- A domain you control, ideally managed in Cloudflare if you're using
  `05-cloudflare-tunnel.sh` for ingress instead of exposing ports directly.
- For `09-qwen-coder-llm.sh`: a CPU with AVX2, ~50GB free disk, and enough
  RAM to fully hold the ~20GB Q4_K_M model (the script checks this and
  aborts if you don't have it).

## Full walkthrough

For a detailed, script-by-script guide (what to check before running each
one, how to verify it worked, and how to reach it afterward), see
[`docs/USER_GUIDE.md`](docs/USER_GUIDE.md).

## Configuration

Copy the example env file and fill in your own domain:

```bash
cp .env.example .env
# edit .env
source .env
```

Every script also falls back to sane defaults (`example.com`, `UTC`, a
random generated password) if you skip this and just run them directly —
`.env` just saves you from re-typing `BASE_DOMAIN=` etc. for every script.
See `.env.example` for the full list of variables each script reads.

## Running the scripts

Run these in order. Scripts `01`–`04` reboot the host at the end of a step
(you'll be prompted `y/N` unless `AUTO_REBOOT=true` is set) — log back in
and re-run the next script afterward.

| # | Script | What it does |
|---|--------|---------------|
| 01 | `01-system-update.sh` | System update, base tools, timezone |
| 02 | `02-firewall.sh` | Opens HTTP/HTTPS and mail ports via firewalld |
| 03 | `03-docker-engine.sh` | Installs Docker CE + Compose plugin |
| 04 | `04-docker-network-nginx.sh` | Creates `proxy-network`, deploys Nginx Proxy Manager |
| 05 | `05-cloudflare-tunnel.sh` | Deploys `cloudflared`, prompts for a tunnel token |
| 06 | `06-n8n.sh` | Deploys n8n behind NPM |
| 07 | `07-portainer.sh` | Deploys Portainer + backup/restore/reset-password helpers |
| 08 | `08-dozzle.sh` | Deploys Dozzle (log viewer) with generated auth credentials |
| 09 | `09-qwen-coder-llm.sh` | Builds `llama.cpp`, downloads Qwen2.5-Coder-32B, deploys Open WebUI (optional, heavy) |
| 10 | `10-tts-api.sh` | Self-hosted text-to-speech API |
| 11 | `11-translate-api.sh` | Self-hosted translation API |
| 12 | `12-stt-api.sh` | Self-hosted speech-to-text API (Arabic + others) |
| 13 | `13-veji-api.sh` | Self-hosted VEJI-V2 Decision API |
| — | `n8n/backup.sh`, `n8n/restore.sh` | Export/import n8n workflows, credentials, and encryption key |

After each service script, the last step it prints is the Nginx Proxy
Manager forward config (hostname/port) and, for the Cloudflare-tunneled
setup, the public hostname to add in the Cloudflare dashboard.

## Security notes

- **Generated secrets are printed once, at the end of each script**, and
  written to that service's `.env` file under `/opt/<service>/` with
  `chmod 600`. Save them somewhere safe immediately — Dozzle's password,
  and the TTS/Translate/STT API keys and Redis passwords, are not stored
  anywhere else by these scripts.
- `n8n/backup.sh` bundles the n8n encryption key into the same archive as
  the workflow/credential export for convenience. That archive can decrypt
  your n8n credentials — store it somewhere at least as protected as the
  credentials themselves (encrypted storage, restricted access), not in a
  public bucket or repo.
- Review `.gitignore` before committing your own fork — it excludes `.env`,
  but double-check you haven't hardcoded anything into a script directly.
- `05-cloudflare-tunnel.sh` asks for your tunnel token interactively so it
  never lands in shell history; you can also pass it via the `TUNNEL_TOKEN`
  env var for unattended runs, but that will end up in your shell history
  or process list unless you're careful.

## Known limitations / things to adapt

- `01`–`06` use `set -e`; `07`–`12` use the stricter `set -Eeuo pipefail`.
  This wasn't unified because tightening it on the earlier scripts risks
  surfacing unset-variable issues that haven't been tested against a live
  run — review before relying on it.
- Scripts assume a single-host deployment; there's no HA/clustering here.
- `09-qwen-coder-llm.sh` hardcodes the Qwen2.5-Coder-32B Q4_K_M model URL —
  swap `MODEL_URL`/`MODEL_FILE` near the top if you want a different size
  or model.

## License 

MIT — see `LICENSE`.
