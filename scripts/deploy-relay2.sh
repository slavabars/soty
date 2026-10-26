#!/usr/bin/env bash
set -euo pipefail

# Soty relay #2 installer/updater (price.dcns.ru, shared hosting).
#
# This box is NOT the main relay and cannot use the systemd-user path of
# deploy-host.sh: there is no sudo, no systemctl, and no tmux. The relay is
# therefore run by a shell supervisor loop plus an @reboot crontab entry, and
# it listens on 127.0.0.1 only — the public endpoint is a TLS WebSocket
# reverse proxy in the provider's nginx (vhost price.dcns.ru, path /soty-ws).
#
# SSH: keyless as `ssh soty-relay2` (alias in ~/.ssh/config, key
# ~/.ssh/id_rsa.1 installed in the remote authorized_keys). No password here.
#
# The eplanet SSH gateway drops connections semi-randomly ("Connection closed
# by ... port 22"), so every remote call is retried a few times.
#
# Upgrade = rebuild the binary + run this script. The sqlite DB is never
# touched, so the Ed25519 identity (and every client pin) stays valid; the
# script fails loudly if the identity changed anyway.
#
#   ./scripts/deploy-relay2.sh                       # update + restart + verify
#   ./scripts/deploy-relay2.sh --check               # verify only, no upload
#   ./scripts/deploy-relay2.sh --app ../build-artifacts/dtm_host.app

ANNOUNCE="wss://price.dcns.ru/soty-ws"
SEED="ws://85.198.75.50:3100/ws|fad55cc762eda3f6cbc9c6522030ce8ec29e87143c9c78f452038d24143a4e82"
EXPECT_ED="dba88ecc7cd8053f76ddbe9c29d0bf63bb24e6234ebcaf9c074dcb0a1ce4b014"
REMOTE="soty-relay2"
REMOTE_DIR="dtm"
DB="\$HOME/$REMOTE_DIR/host.db"
APP="../build-artifacts/dtm_host.app"
CHECK_ONLY=0

die() { echo "error: $*" >&2; exit 1; }
usage() {
  sed -n '2,25p' "$0" | sed 's/^#\s\?//'
  cat <<'EOF'
Флаги:
  --app PATH     локальный dtm_host.app (default: ../build-artifacts/dtm_host.app)
  --check        только проверка (identity + публичный wss), без заливки
  --expect-ed HEX  ожидаемый Ed25519 публичный ключ (default: зашитый в скрипт)
EOF
  exit 0
}
[ $# -gt 0 ] && case "$1" in --help|-h) usage;; esac

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2;;
    --check) CHECK_ONLY=1; shift;;
    --expect-ed) EXPECT_ED="$2"; shift 2;;
    --help|-h) usage;;
    *) die "неизвестный флаг: $1 (--help)";;
  esac
done

# The provider gateway hangs up on maybe 1 in 3 connections; retry instead of
# failing a release step. Output containing "Connection closed" is a failure
# even when the exit code is 0.
rsh() {
  local out="" rc=0 i
  for i in 1 2 3 4 5 6; do
    set +e
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE" "$1" 2>&1)
    rc=$?
    set -e
    if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q "Connection closed"; then
      printf '%s\n' "$out"; return 0
    fi
    sleep $((4 + i * 4))
  done
  printf '%s\n' "$out" >&2
  return 1
}

echo "==> ssh $REMOTE ..."
rsh 'true' >/dev/null || die "ssh $REMOTE не работает (ключ ~/.ssh/id_rsa.1 в authorized_keys?)"

if [ "$CHECK_ONLY" -eq 0 ]; then
  [ -f "$APP" ] || die "нет бинаря: $APP (сначала: cd host && dart compile exe bin/dtm_host.dart -o ../$APP)"
  rsh "mkdir -p \$HOME/$REMOTE_DIR"
  echo "==> заливаю $APP -> $REMOTE:$REMOTE_DIR/dtm_host.app.new"
  scp -o BatchMode=yes -o ConnectTimeout=20 "$APP" "$REMOTE:$REMOTE_DIR/dtm_host.app.new" \
    || die "scp не удался"
  LOCAL_SUM=$(sha256sum "$APP" | awk '{print $1}')
  REMOTE_SUM=$(rsh "sha256sum $REMOTE_DIR/dtm_host.app.new" | awk '{print $1}' | tail -1)
  [ "$LOCAL_SUM" = "$REMOTE_SUM" ] || die "sha256 не совпал: $LOCAL_SUM vs $REMOTE_SUM"
  echo "    sha256 $REMOTE_SUM"

  echo "==> ставлю supervise/start/stop/status и перезапускаю ..."
  rsh "bash -s" <<EOF
set -e
cd "\$HOME/$REMOTE_DIR"
# The running process cmdline is \`./dtm_host.app --db ...\`, so a pkill
# pattern like \`dtm/$REMOTE_DIR/dtm_host.app\` never matches it: use the bare
# binary name (nothing else on this box is called dtm_host.app).
cat > supervise.sh <<'SH'
#!/bin/bash
# No systemd here (no sudo, no systemctl): this loop is the supervisor.
cd "\$HOME/$REMOTE_DIR"
while true; do
  ./dtm_host.app \\
    --db "$DB" \\
    --listen 127.0.0.1 \\
    --port 3100 \\
    --announce "$ANNOUNCE" \\
    --seed "$SEED" \\
    >> "\$HOME/$REMOTE_DIR/host.log" 2>&1
  echo "--- dtm_host exited rc=\$? at \$(date -Is), restarting in 5s ---" >> "\$HOME/$REMOTE_DIR/host.log"
  sleep 5
done
SH
cat > start.sh <<'SH'
#!/bin/bash
pkill -f 'supervise.sh' 2>/dev/null
pkill -f 'dtm_host.app' 2>/dev/null
sleep 2
nohup setsid "\$HOME/$REMOTE_DIR/supervise.sh" >/dev/null 2>&1 &
sleep 6
pgrep -af dtm_host.app || echo "  NOT RUNNING"
SH
cat > stop.sh <<'SH'
#!/bin/bash
pkill -f 'supervise.sh' 2>/dev/null
pkill -f 'dtm_host.app' 2>/dev/null
sleep 2
if pgrep -f dtm_host.app >/dev/null; then echo "  still running"; else echo "stopped"; fi
SH
cat > status.sh <<'SH'
#!/bin/bash
pgrep -af dtm_host.app || echo "NOT RUNNING"
echo "--- log tail ---"
tail -n 20 "\$HOME/$REMOTE_DIR/host.log" 2>/dev/null || echo "no log yet"
SH
chmod 700 supervise.sh start.sh stop.sh status.sh
( crontab -l 2>/dev/null | grep -v "$REMOTE_DIR/start.sh"; echo "@reboot \$HOME/$REMOTE_DIR/start.sh" ) | crontab -
# Swap the binary in only after the new unit scripts are on disk, then restart.
mv -f dtm_host.app.new dtm_host.app
chmod 700 dtm_host.app
./start.sh
EOF
fi

echo "==> identity (must stay $EXPECT_ED) ..."
ED=$(rsh "grep -Eo 'ed25519 [0-9a-f]{64}' \$HOME/$REMOTE_DIR/host.log | tail -1 | awk '{print \$2}'" | tail -1)
[ -n "$ED" ] || die "не нашёл ed25519 в host.log (реле вообще не стартовало?)"
if [ "$ED" != "$EXPECT_ED" ]; then
  die "IDENTITY CHANGED: $ED != $EXPECT_ED — клиенты с пином $EXPECT_ED отвалятся. Разбирайся."
fi
echo "    $ED (пины клиентов валидны)"

echo "==> публичный wss через nginx ..."
PROBE=$(python3 "$(dirname "$0")/host_probe.py" "$ANNOUNCE" "$ED" 2>&1) \
  || die "публичный $ANNOUNCE не отвечает корректным WELCOME:
$PROBE"
printf '%s\n' "$PROBE" | sed 's/^/    /'

echo "==> федерация с основным хостом ..."
rsh "python3 -c \"
import sqlite3
c = sqlite3.connect('file:\$HOME/$REMOTE_DIR/host.db?mode=ro', uri=True)
for r in c.execute('select addr, ed_pub_key, last_seen from federated_hosts'):
    print('   ', r[0], 'last_seen=' + str(r[2]))
\"" || true

cat <<EOF

==> relay #2 ($ANNOUNCE) обновлён и отвечает
    ssh $REMOTE        # ~/dtm/{status.sh,start.sh,stop.sh,host.log,host.db}
    ed25519            $ED
    invite             soty://host?addr=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$ANNOUNCE")&pk=$ED

    Не забудь про основной релей 85.198.75.50:3100 — он обновляется
    scripts/deploy-host.sh (systemd-user) и его ПК не меняется:
    fad55cc762eda3f6cbc9c6522030ce8ec29e87143c9c78f452038d24143a4e82
EOF
