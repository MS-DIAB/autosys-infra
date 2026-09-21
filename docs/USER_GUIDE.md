# User Guide

This walks through deploying the full stack end to end: what each script
does, what to check before running it, and how to reach the service
afterward. For the one-line description of each script, see the table in
`README.md` — this doc goes deeper.

## 0. Before you start

- A fresh Rocky Linux / RHEL-family VM or bare-metal box, with a non-root
  sudo user.
- A domain you control. If you're using `05-cloudflare-tunnel.sh`, that
  domain should be on Cloudflare (free tier is fine).
- Copy the config and fill in your domain:
  ```bash
  cp .env.example .env
  nano .env          # set BASE_DOMAIN, TIMEZONE, etc.
  source .env
  ```
  Re-run `source .env` in every new shell session before running a script,
  or `export` the variables another way (e.g. your shell profile).
- Transfer the `scripts/` folder to the server (`scp -r scripts/ user@server:~/`),
  or `git clone` your published repo directly onto it.

## 1. System update & timezone — `01-system-update.sh`

```bash
bash scripts/01-system-update.sh
```
Updates packages, installs `curl wget nano git unzip tar net-tools`, and
sets the system timezone to `$TIMEZONE` (default `UTC`). Ends by asking to
reboot — say yes (or set `AUTO_REBOOT=true` beforehand to skip the prompt).

**After reboot:** log back in and `cd` back into the repo before continuing.

## 2. Firewall — `02-firewall.sh`

```bash
bash scripts/02-firewall.sh
```
Enables `firewalld` and opens 80, 81, 443 (HTTP/HTTPS/NPM admin) and the
mail ports 25/465/587/143/993/110/995. If you don't plan to self-host
email, feel free to comment those lines out before running it. Asks to
reboot at the end.

## 3. Docker Engine — `03-docker-engine.sh`

```bash
bash scripts/03-docker-engine.sh
```
Adds Docker's official repo and installs `docker-ce`, the Compose plugin,
and adds your user to the `docker` group. Asks to reboot (needed for the
group membership to take effect cleanly).

**Verify:** `docker --version && docker compose version`

## 4. Docker network + Nginx Proxy Manager — `04-docker-network-nginx.sh`

```bash
bash scripts/04-docker-network-nginx.sh
```
Creates the `proxy-network` bridge every other service attaches to, and
deploys **Nginx Proxy Manager** (NPM) at `/opt/npm`. Asks to reboot at the
end (safe to skip here — `AUTO_REBOOT=false` and just say no if you'd
rather keep going).

**First login:** open `http://<server-ip>:81`. NPM's default first-run
credentials are `admin@example.com` / `changeme` — you'll be forced to set
a new email and password immediately. Do this before exposing port 81
publicly, and ideally firewall port 81 to your own IP only once you're
past first setup.

From here on, every service script prints an NPM "Forward" block at the
end — in NPM: **Hosts → Proxy Hosts → Add Proxy Host**, put the service's
domain in "Domain Names", and the forward hostname/port from that block
under "Details". Enable **Block Common Exploits**, **Websockets Support**,
then on the SSL tab **Force SSL**, **HTTP/2**, **HSTS**, and request a Let's
Encrypt certificate.

## 5. Cloudflare Tunnel — `05-cloudflare-tunnel.sh`

```bash
bash scripts/05-cloudflare-tunnel.sh
```
Optional, but recommended if you don't want to open 80/443 to the internet
directly. Deploys `cloudflared` on `proxy-network`. You'll need a tunnel
token first:

1. Cloudflare dashboard → Zero Trust → Networks → Tunnels → Create a
   tunnel (Cloudflared type) → copy the token shown.
2. Paste it when the script prompts (it won't echo to the terminal), or
   set `TUNNEL_TOKEN` in the environment beforehand for unattended runs.

For each service, add a **Public Hostname** in that tunnel pointing at the
container (e.g. `http://npm:80`) rather than opening firewall ports for it.

## 6. n8n — `06-n8n.sh`

```bash
bash scripts/06-n8n.sh
```
Deploys n8n at `/opt/n8n`, wired to `N8N_DOMAIN`. NPM forward: `n8n` →
`5678`, scheme `http`. First visit to `https://$N8N_DOMAIN` walks you
through creating the owner account.

**Backup / restore** (`scripts/n8n/`):
```bash
bash scripts/n8n/backup.sh                                  # -> /opt/n8n/backups/n8n_export_<timestamp>.tar.gz
bash scripts/n8n/restore.sh /opt/n8n/backups/n8n_export_<timestamp>.tar.gz
```
The backup archive bundles the encryption key together with the exported
credentials — treat it as sensitive (see README's Security notes).

## 7. Portainer — `07-portainer.sh`

```bash
bash scripts/07-portainer.sh
```
Deploys Portainer at `/opt/portainer`, and writes `backup.sh`,
`restore.sh`, and `reset-password.sh` helpers into that same directory.
NPM forward: `portainer` → `9000`, scheme `http`.

**Important:** create the admin account within **5 minutes** of the
container starting — Portainer locks the initial setup window after that.
If you miss it, run `/opt/portainer/reset-password.sh`.

## 8. Dozzle — `08-dozzle.sh`

```bash
bash scripts/08-dozzle.sh
```
Deploys Dozzle (live container log viewer) at `/opt/dozzle`. NPM forward:
`dozzle` → `8080`, scheme `http`. Generates a random password unless you
set `DOZZLE_PASSWORD` — **it's printed once at the end and saved to
`/opt/dozzle/.env` (chmod 600)**. Copy it somewhere safe immediately.

Add more users later with `/opt/dozzle/add-user.sh <username> <password>
<full name> <email>`, or rotate a password with
`/opt/dozzle/change-password.sh <username> <new password>`.

## 9. Qwen2.5-Coder LLM + Open WebUI — `09-qwen-coder-llm.sh` (optional, heavy)

```bash
bash scripts/09-qwen-coder-llm.sh
```
Only run this if you actually want a local coding LLM — it downloads a
~20GB model and needs a CPU with AVX2 plus enough RAM to `mlock` the whole
model in memory (the script checks and aborts if you don't have it). It:

1. Builds `llama.cpp` natively (CPU-optimized, `-DGGML_NATIVE=ON`).
2. Downloads `Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf`.
3. Benchmarks tokens/sec before committing to running it as a service.
4. Installs `llama-server` as a systemd service on port 8080 (bound to
   `0.0.0.0` for Docker containers to reach it, but **not** opened in
   firewalld — verify with `sudo firewall-cmd --list-ports`).
5. Deploys Open WebUI as the chat frontend, bound to `127.0.0.1:3000`
   only — reach it via SSH tunnel (`ssh -L 3000:localhost:3000
   user@server`) or add an NPM/Cloudflare Access-gated hostname yourself
   if you want it reachable from elsewhere. The script deliberately
   doesn't expose it publicly by default.

**Verify:** `systemctl status llama-server` and
`curl http://localhost:8080/v1/models`.

## 10. TTS API — `10-tts-api.sh`

```bash
bash scripts/10-tts-api.sh
```
Fully builds and starts the stack (Redis, Arabic XTTS engine, English
Kokoro engine, router) without a manual gate — it waits for each engine's
healthcheck before starting the next. Prints `API_SECRET_KEY` and
`ADMIN_API_KEY` once at the end (also saved to `.env` under the install
dir) — save these immediately. The router isn't bound to a host port; add
an NPM proxy host forwarding to the `tts-v4-router` container on its
internal port if you want it reachable by domain.

Before treating it as production-ready, the script's own summary lists a
required checklist (exporting n8n workflows, running the language audit
script, rebuilding the router, benchmarking against the previous version)
— read that output before moving on.

## 11. Translate API — `11-translate-api.sh` (internal-only, gated)

```bash
bash scripts/11-translate-api.sh
```
This one behaves differently from the others on purpose: it's designed as
an **internal-only** service (Nginx bound to `127.0.0.1:5080`, no public
exposure) and **stops after generating files** — it does not build or
start containers for you. Follow the "Next steps" it prints:

```bash
cd /opt/translate-api-v4        # or wherever TRANSLATE_API_DIR points
stat -c '%a %U:%G %n' .env      # confirm .env permissions before going further
./download-model.sh             # pulls the NLLB model
./gate.sh                       # review gate — checks config before allowing a build
docker compose build --pull
docker compose up -d
curl -i http://127.0.0.1:5080/health/live
curl -i http://127.0.0.1:5080/health/ready
```
The admin API key is saved to `.api_key` in that directory — as the
script itself warns, don't paste `.env` or `.api_key` into chat, git, or
tickets. If you actually want this reachable from outside the host, put
it behind a VPN or SSH tunnel rather than opening it up — that was the
explicit design intent.

## 12. STT API — `12-stt-api.sh`

```bash
bash scripts/12-stt-api.sh
# or, to regenerate config from scratch on an upgrade:
bash scripts/12-stt-api.sh --force
```
CPU+RAM only (no GPU required). Deploys a router plus multilingual,
Arabic, and Whisper-fallback engines, each internal-only on
`proxy-network`; the router alone is reachable at
`127.0.0.1:${ROUTER_PORT}` (default `8090`) for local debugging. NPM
forward: `stt-router` → `8000`, scheme `http`. Optionally prompts for a
Hugging Face token (only needed for gated models) — set `STT_HF_TOKEN`
beforehand to skip the prompt.

The script health-checks that each model actually loaded into RAM, not
just that the container is running, and prints a production checklist at
the end (dialect gate classifier, threshold calibration, audit logging
sign-off) — read it before relying on this for real traffic.

## Verifying everything is up

```bash
docker ps                                   # every expected container should show "healthy" or "Up"
curl -i https://$N8N_DOMAIN/healthz
curl -i https://<your-dozzle-domain>
curl -i http://127.0.0.1:${ROUTER_PORT:-8090}/health   # STT router, from the host
```

## Troubleshooting

- **A container won't start:** `docker compose -f /opt/<service>/docker-compose.yml logs --tail 100 <container>`.
- **NPM shows a 502:** the upstream container isn't healthy yet, or you
  typed the wrong forward hostname/port — forward hostnames are Docker
  container names, only resolvable from containers on `proxy-network`,
  not from the host.
- **Reboot prompt didn't appear / script exited instead:** you're running
  non-interactively (e.g. over a pipe) — set `AUTO_REBOOT=true` first.
- **Lost a generated password:** check that service's `/opt/<service>/.env`
  — every script writes its secrets there before printing them.

## Tearing a service down

Each service lives entirely under its own `/opt/<service>/` directory:
```bash
cd /opt/<service>
docker compose down          # stop and remove containers
# rm -rf /opt/<service>      # only if you also want to delete its data/volumes
```
Removing a service doesn't touch `proxy-network`, NPM, or anything else.
