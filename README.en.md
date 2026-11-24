# Soty (DTM) — a serverless E2EE messenger

[Русский](README.md) · **English**

[![Repository invariants](https://github.com/slavabars/soty/actions/workflows/invariants.yml/badge.svg)](https://github.com/slavabars/soty/actions/workflows/invariants.yml) [![Latest release](https://img.shields.io/github/v/release/slavabars/soty?label=release)](https://github.com/slavabars/soty/releases) [![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](https://github.com/slavabars/soty-app/blob/main/LICENSE)

Soty is a decentralized text messenger with end-to-end encryption. Devices talk to each other directly: offline over a mesh (BLE / Wi-Fi Direct), online over libp2p. There are no accounts and no central server. Relay hosts (`dtm_host`) are operator-run nodes that deliver encrypted envelopes while a recipient is offline and publish peer discovery (a tracker). Plaintext and keys never live on a host.

## Where things live

The code is split into separate repositories so the app, the relay and the website have their own visibility boundaries and release cadence:

| Repository | What it is | Access |
| --- | --- | --- |
| **soty** (this one) | Project description, relay install and deploy, releases | public |
| [`soty-app`](https://github.com/slavabars/soty-app) | Client source (Flutter: Android, Linux, macOS) | public |
| [`soty-relay`](https://github.com/slavabars/soty-relay) | Relay host `dtm_host` source | public |

The source is published separately: it has passed the security audit and the secret-leak check, so the app, the relay and the website live in their own repositories with different visibility.

## What is in this repository

| Path | What it is |
| --- | --- |
| `README.md` | Project description and the relay-host deployment guide |
| `scripts/install-relay.sh` | Linux install: distro autodetection, root or user |
| `scripts/install-relay-macos.sh` | macOS install through Docker/Colima (no admin) |
| `scripts/install-relay-windows.ps1` | Windows install through Docker Desktop (no admin) |
| `scripts/deploy-host.sh` | Install/update a relay on a regular Linux server over SSH (systemd --user) |
| `scripts/deploy-relay2.sh` | Install/update a relay on shared hosting (shell supervisor + nginx) |
| `scripts/host_probe.py` | Check a live relay with the same handshake the app uses |
| `scripts/soty-ws-nginx-location.conf` | nginx location for the relay WebSocket, `/soty-status` and `/soty-directory` |

The app and relay source is not here: it lives in [`soty-app`](https://github.com/slavabars/soty-app) and [`soty-relay`](https://github.com/slavabars/soty-relay). Ready-made builds (Android APK/AAB, Linux desktop, the `dtm_host` binary) are published only in [Releases](https://github.com/slavabars/soty/releases). This repository intentionally contains only the project description and the relay-host deployment tooling.

## How federation works

- `dtm_host` accepts WebSocket connections on `/ws` and stores encrypted envelopes in SQLite. Clients receive offline messages once they reconnect.
- Every `dtm_host` also acts as a tracker: it remembers client addresses and returns a peer list on request so devices can connect directly.
- Hosts federate with the `--peer` / `--seed` flags: they run a live relay link and anti-entropy (catching up on missed envelopes). For two-way delivery every node must know the others (or learn them from `NET`).
- A host identity is an Ed25519 key generated on first start and stored in `host.db`. Clients pin that key, so **the database must never be deleted on upgrade**.

## Relay server requirements

- Linux x86_64 is the primary target (root or a regular user).
- macOS (Intel/Apple Silicon) and Windows run through Docker only: the published `dtm_host.bin` is built for Linux x86_64. The installers build a small `debian:bookworm-slim` container with `libsqlite3` and run the relay inside it.
- `libsqlite3` on Linux (Alma/RHEL: `dnf install -y sqlite-libs`; Debian/Ubuntu: `apt-get install -y libsqlite3-0`). The Linux installer installs the dependency itself when run as root.
- A system `systemctl --user` (for relay #1) **or** nginx + cron (for shared hosting, relay #2). Without systemd the Linux installer falls back to a shell supervisor plus `@reboot` in crontab.
- An open port (usually 3100) or a TLS proxy in nginx on 80/443.
- The `dtm_host` binary from Releases. It is called `dtm_host.bin` in a release; do not rename it — the installers do that themselves.

## Quick install on a relay machine

The installers download the current `dtm_host.bin` from GitHub Releases, verify its SHA-256 through the GitHub API, install dependencies and start the service. Running them again updates the binary and **leaves `host.db` alone**, so the Ed25519 identity and the client pins survive.

Linux autodetects the distribution (apt/dnf/yum/pacman/zypper) and the architecture. It needs glibc x86_64; there is no binary for Alpine/musl or ARM. Root mode installs a system service under the `soty` user; user mode uses `systemd --user`, and without it, a supervisor in `~/.local/share/soty`:

```bash
# system-wide install
curl -fsSL https://raw.githubusercontent.com/slavabars/soty/main/scripts/install-relay.sh \
  | sudo bash -s -- --port 3100 --announce wss://relay.example.com/soty-ws

# without root
curl -fsSL https://raw.githubusercontent.com/slavabars/soty/main/scripts/install-relay.sh \
  | bash -s -- --port 3100 --announce wss://relay.example.com/soty-ws
```

macOS uses Docker Desktop or Colima and needs no admin. If Docker is missing, the same script installs it through Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/slavabars/soty/main/scripts/install-relay-macos.sh \
  | bash -s -- --install-docker --port 3100 \
      --announce wss://relay.example.com/soty-ws
```

Windows uses Docker Desktop and needs no admin when Docker is already installed:

```powershell
$dst = "$env:TEMP\install-relay-windows.ps1"
iwr https://raw.githubusercontent.com/slavabars/soty/main/scripts/install-relay-windows.ps1 -UseBasicParsing -OutFile $dst
powershell -ExecutionPolicy Bypass -File $dst -Port 3100 -Announce wss://relay.example.com/soty-ws
# install Docker Desktop (needs an administrator PowerShell):
powershell -ExecutionPolicy Bypass -File $dst -InstallDocker
```

Useful Linux/macOS flags (Windows has the matching `-Port`, `-Announce`, `-Peer`, `-Version`, `-Uninstall`, `-Purge` parameters):

| Flag | Meaning |
| --- | --- |
| `--port`, `--listen` | bind port and address (default `3100`, `0.0.0.0`) |
| `--announce` | public `ws://…/ws` or `wss://…` used in the invite |
| `--peer SPEC` | federation peer, repeatable |
| `--version X.Y.Z+N` | a specific version instead of latest |
| `--url URL` | direct URL to `dtm_host.bin` |
| `--no-verify` | skip the SHA-256 check |
| `--no-service` | download/install only, do not start |
| `--uninstall [--purge]` | remove the service; `--purge` also removes `host.db` |

After installing, the script prints the `ed25519` key and a ready invite link. On Linux root mode: `systemctl status soty-host`, `journalctl -u soty-host -f`; without root: `systemctl --user status soty-host` (enable `loginctl enable-linger $USER`). On macOS/Windows: `docker logs -f soty-host`.

## Relay #1 — a regular Linux server (systemd --user)

`scripts/deploy-host.sh` uploads the new binary next to the running one (`dtm_host.app.new`), replaces it with a rename and restarts the service — so the update never hits a busy file (ETXTBSY) and never needs a manual stop. The script checks `libsqlite3`, puts the binary in `~/local/` and the database in `~/soty/host.db`, creates a user systemd unit `soty-host.service` with `--announce` and prints the invite link.

```bash
# binary from Releases
mkdir -p build-artifacts
curl -L -o build-artifacts/dtm_host.app \
  https://github.com/slavabars/soty/releases/latest/download/dtm_host.bin
chmod +x build-artifacts/dtm_host.app

# SSH password without sshpass — through SSH_ASKPASS:
cat > /tmp/askpass.sh <<'EOF'
#!/bin/sh
echo "YOUR_PASSWORD"
EOF
chmod +x /tmp/askpass.sh
export SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0

./scripts/deploy-host.sh \
  --user dtm --host 77.246.145.113 \
  --listen 0.0.0.0 --port 3100 \
  --app build-artifacts/dtm_host.app
```

If an SSH key is already configured, `SSH_ASKPASS` is not needed.

`deploy-host.sh` flags:

| Flag | Meaning |
| --- | --- |
| `--user`, `--host` | SSH user and server (required) |
| `--app PATH` | local binary (default `../build-artifacts/dtm_host.app`) |
| `--listen`, `--port` | bind address and port (default `0.0.0.0:3100`) |
| `--announce URL` | public `ws://…/ws` or `wss://…` (default `ws://HOST:PORT/ws`) |
| `--name` | systemd unit name (default `soty-host`) |
| `--remote-dir` | binary directory (default `~/local`) |
| `--unit-only` | only recreate the unit, do not upload the binary |
| `--restart-on-fail` | `Restart=on-failure` (the default) |
| `--no-restart` | do not restart the service |
| `--invite-json` | print endpoint/ed25519/invite as JSON |

After installing:

```bash
ssh dtm@77.246.145.113 'systemctl --user status soty-host'
ssh dtm@77.246.145.113 'journalctl --user -u soty-host -n 50 --no-pager'
```

So the user service does not stop when the SSH session ends, enable lingering once as root: `loginctl enable-linger dtm`.

An invite link looks like this:

```text
soty://host?addr=ws%3A%2F%2F77.246.145.113%3A3100%2Fws&pk=<ed25519-hex>
```

You can bake it into the app or import it under "Relay hosts" in Settings. The `ed25519` key in the invite is mandatory: without it the client does not pin the relay.

## Relay #2 — shared hosting behind nginx (TLS, no systemd)

On hosting without root or systemctl the relay listens only on `127.0.0.1:3100` and faces the world through nginx as `wss://`. A shell supervisor keeps the process alive (`supervise.sh` plus an `@reboot` crontab entry). `deploy-relay2.sh` sets all of this up, restarts and verifies it.

```bash
./scripts/deploy-relay2.sh --check   # verify only, no upload
./scripts/deploy-relay2.sh           # update, restart, verify
```

Defaults (baked into the script): SSH alias `soty-relay2`, directory `~/dtm/`, public address `wss://price.dcns.ru/soty-ws`, a seed pointing at relay #1 and the expected Ed25519 key. Override the binary or the key:

```bash
./scripts/deploy-relay2.sh --app build-artifacts/dtm_host.app
./scripts/deploy-relay2.sh --expect-ed <hex>
```

The script fails with `IDENTITY CHANGED` when the Ed25519 key in `host.log` does not match the expected one: that means pinned clients will drop the relay, so the update must stop. `host.db` is never touched.

### nginx for relay #2

The ready config is `scripts/soty-ws-nginx-location.conf`. Put it in `/etc/nginx/vhosts-resources/price.dcns.ru/soty-ws.conf` (the include is already present in both provider `server{}` blocks) and run `nginx -t && nginx -s reload`.

```nginx
location = /soty-ws {
    proxy_pass http://127.0.0.1:3100/ws;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_pass_header Upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}

location = /soty-status {
    limit_except GET { deny all; }
    proxy_pass http://127.0.0.1:3100/status;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
}

location = /soty-directory {
    limit_except GET { deny all; }
    proxy_pass http://127.0.0.1:3100/directory;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
}
```

`/soty-status` serves the aggregates for the public table at `soty.su/status`, and `/soty-directory` serves the federation directory the site uses to discover new relays. Without these two locations the relay still shows in the table, but without metrics or its own directory entry.

A typical `server{}` with TLS termination:

```nginx
server {
    listen 443 ssl http2;
    server_name relay.example.com;

    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;

    location = /soty-ws {
        proxy_pass http://127.0.0.1:3100/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass_header Upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

server {
    listen 80;
    server_name relay.example.com;
    return 301 https://$host$request_uri;
}
```

Why it is done this way:

- `proxy_read_timeout 3600s` is mandatory: the default 60 s tears down an idle subscription every minute.
- `proxy_http_version 1.1` plus `Upgrade`/`Connection` enable WebSocket.

- If nginx sits in front of Apache/Hestia, the vhost template often contains `proxy_hide_header Upgrade;`: add `proxy_pass_header Upgrade;` to `location = /soty-ws`. Otherwise `curl`/`host_probe` see `101`, while the Dart client fails with `Null check operator` and the relay looks disconnected.
- If :80 redirects to :443, the public relay address must be `wss://` only; `ws://` on :80 will not work.
- If the relay is down, the proxy returns 502 — the site itself is unaffected.

## Relay federation

Relay #2 already starts with `--seed` pointing at relay #1. The primary node learns the second address from the `NET` greeting and stores it in the `federated_hosts` table. For an arbitrary topology, start hosts like this:

```bash
# host 1
./dtm_host.app --db /srv/host1.db --listen 0.0.0.0 --port 3100 \
  --announce ws://relay1.example.com/ws \
  --peer "ws://relay2.example.com/ws|<ed25519-relay2>"

# host 2
./dtm_host.app --db /srv/host2.db --listen 0.0.0.0 --port 3100 \
  --announce ws://relay2.example.com/ws \
  --peer "ws://relay1.example.com/ws|<ed25519-relay1>"
```

- `--peer ws://url/ws` is unpinned; `--peer "ws://url/ws|hex"` pins the Ed25519 key. A `WELCOME.identity` mismatch closes the connection.
- `--seed` is an alias for `--peer` aimed at an already running node.
- Federation is built on outbound links. For a full mesh every node must list the others; long chains are limited by a hop cap, so keep the path to a recipient at 2–3 hops.
- Host keys come from their banners (`ed25519 <hex>`) and stay stable for as long as `host.db` lives.

## Checking a relay

`host_probe.py` performs the same WebSocket handshake and verifies the Ed25519 key:

```bash
python3 scripts/host_probe.py \
  wss://soty.su/soty-ws \
  fad55cc762eda3f6cbc9c6522030ce8ec29e87143c9c78f452038d24143a4e82

python3 scripts/host_probe.py \
  wss://price.dcns.ru/soty-ws \
  dba88ecc7cd8053f76ddbe9c29d0bf63bb24e6234ebcaf9c074dcb0a1ce4b014
```

The expected result is a `WELCOME` carrying the same key. For relay #2, `./scripts/deploy-relay2.sh --check` does the same.

## Updating relays

1. The simplest path is to run the installer again on each machine: it downloads the fresh `dtm_host.bin`, verifies the SHA-256 and restarts the service. `host.db` is unchanged and the Ed25519 identity survives:

```bash
# Linux
sudo ./scripts/install-relay.sh --announce wss://relay.example.com/soty-ws
# macOS
./scripts/install-relay-macos.sh --announce wss://relay.example.com/soty-ws
# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File .\install-relay-windows.ps1 -Announce wss://relay.example.com/soty-ws
```

2. Or update over SSH with the older scripts:

```bash
./scripts/deploy-host.sh --user dtm --host 77.246.145.113 --announce wss://soty.su/soty-ws --invite-json
./scripts/deploy-relay2.sh
```

3. Update **both** nodes, otherwise they drift apart on the protocol version, and verify each one with `host_probe.py` / `--check`.

## Operations and security

- Do not delete `host.db`: it holds the Ed25519 key and history. Losing the database means `IDENTITY CHANGED` and invalid pins on every client.
- A relay stores only encrypted envelopes in a bounded window plus the tracker table; keys and plaintext are out of reach.
- TLS is mandatory for a public relay outside a local network. Use `wss://` and pin the Ed25519 key in the invite link.
- Relay #1 logs: `journalctl --user -u soty-host`; relay #2: `~/dtm/host.log` and `~/dtm/status.sh`.
- Restart relay #1 with `systemctl --user restart soty-host`; relay #2 with `~/dtm/start.sh` (or `stop.sh`).
