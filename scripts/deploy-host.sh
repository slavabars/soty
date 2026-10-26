#!/usr/bin/env bash
set -euo pipefail

# Soty host installer.
#
# Копирует dtm_host.app на удалённый сервер по SSH и поднимает его как
# user-systemd-сервис (без root). Выводит баннер с invite-линком и ключом.
#
# Поддержка пароля (нет sshpass): задай SSH_ASKPASS-скрипт, например
#   export SSH_ASKPASS="/tmp/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
# или настрой ключи (ssh-copy-id).
#
# Пример:
#   ./deploy-host.sh \
#     --user dtm --host 85.198.75.50                        \
#     --listen 0.0.0.0 --port 3100                          \
#     --app  ../build-artifacts/dtm_host.app
#   ./deploy-host.sh --user dtm --host 85.198.75.50 --invite-json

die() { echo "error: $*" >&2; exit 1; }
usage() {
  sed -n '2,12p' "$0" | sed 's/^#\s\?//'
  cat <<'EOF'
Флаги (обязательны: --user, --host):
  --user USER             ssh-пользователь            (обязательно)
  --host HOST             IP/домен сервера            (обязательно)
  --app PATH              локальный dtm_host.app      (default: ../build-artifacts/dtm_host.app)
  --listen IP             bind: 0.0.0.0 / 127.0.0.1   (default: 0.0.0.0)
  --port PORT             bind-порт                   (default: 3100)
  --name NAME             имя unit'а                  (default: soty-host)
  --remote-dir DIR        каталог бинаря на сервере   (default: ~/local)
  --unit-only             только (пере)создать unit, не перезаливать бинарь
  --restart-on-fail       Restart=on-failure (default)
  --no-restart            убрать Restart=
  --invite-json           вывести invite как JSON (для скриптов)
EOF
  exit 0
}

[ $# -eq 0 ] && usage

APP="../build-artifacts/dtm_host.app"
LISTEN="0.0.0.0"
PORT=3100
NAME="soty-host"
UNIT_ONLY=0
RESTART="on-failure"
INVITE_JSON=0
REMOTE_DIR=""
DB_DIR=""
USER=""
HOST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    --app)  APP="$2";  shift 2;;
    --listen) LISTEN="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --remote-dir) REMOTE_DIR="$2"; shift 2;;
    --db-dir) DB_DIR="$2"; shift 2;;
    --unit-only) UNIT_ONLY=1; shift;;
    --no-restart) RESTART="no"; shift;;
    --invite-json) INVITE_JSON=1; shift;;
    --help|-h) usage;;
    *) die "неизвестный флаг: $1 (--help)" ;;
  esac
done

[ -n "$USER" ] || die "--user обязателен"
[ -n "$HOST" ] || die "--host обязателен"

SSH_DEST="$USER@$HOST"
ssh() { command ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$SSH_DEST" "$@"; }

echo "==> ssh-доступ к ${SSH_DEST} ..."
ssh 'true' || die "ssh не работает до $SSH_DEST (пароль/ключ?)"
REMOTE_HOME=$(ssh 'printf %s "$HOME"')
[ -n "$REMOTE_HOME" ] || die "не удалось определить HOME"

[ -n "$REMOTE_DIR" ] || REMOTE_DIR="$REMOTE_HOME/local"
CMD_DIR="$REMOTE_DIR"
[ -n "$DB_DIR" ] || DB_DIR="$REMOTE_HOME/soty"
DATA_DIR="$DB_DIR"

# --- проверка sqlite (dtm_host собирается с внешним libsqlite3) ---
echo "==> проверка libsqlite3 ..."
if ! ssh 'test -f /usr/lib64/libsqlite3.so.0 -o -f /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 -o -f /lib/x86_64-linux-gnu/libsqlite3.so.0' ; then
  die "на сервере нет libsqlite3 (нужны sqlite-libs: dnf install -y sqlite-libs"
fi

ssh 'mkdir -p' "$(printf '%q' "$CMD_DIR")" "$(printf '%q' "$DATA_DIR")"

# --- копирование бинаря ---
if [ "$UNIT_ONLY" -eq 0 ]; then
  [ -f "$APP" ] || die "нет бинаря: $APP (сначала: flutter build / dart compile)"
  echo "==> копирую $APP -> $SSH_DEST:$CMD_DIR/dtm_host.app"
  command scp -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$APP" "$SSH_DEST:$CMD_DIR/dtm_host.app" || die "scp не удался"
fi

# --- systemd-user unit ---
UNIT_PATH="$REMOTE_HOME/.config/systemd/user/$NAME.service"
SVC="
[Unit]
Description=Soty relay host + tracker
After=network.target

[Service]
ExecStart=%h/local/dtm_host.app --db %h/soty/host.db --listen $LISTEN --port $PORT
Restart=$RESTART
RestartSec=5

[Install]
WantedBy=default.target
"
echo "==> пишу unit: $UNIT_PATH"
ssh 'bash -s' <<EOF
set -e
mkdir -p "$(printf '%q' "$REMOTE_HOME")/.config/systemd/user"
cat > "$(printf '%q' "$UNIT_PATH")" <<'UNIT'
$SVC
UNIT
systemctl --user daemon-reload
systemctl --user enable --now "$(printf '%q' "$NAME")" 2>&1
EOF

sleep 3
echo "==> статус:"
ssh 'systemctl --user is-active' "$NAME"

# --- снимаю баннер и ключ из журнала сервиса ---
BANNER=$(ssh 'journalctl --user -u' "$NAME" --no-pager -n 200 2>/dev/null | grep -Eo 'ed25519 [0-9a-f]{64}' | tail -1 | awk '{print $2}')
if [ -z "$BANNER" ]; then
  echo "==> предупреждение: не удалось извлечь Ed25519-ключ из журнала."
  echo "    возьми его вручную: journalctl --user -u $NAME --no-pager | grep ed25519"
  BANNER="НЕИЗВЕСТНО"
fi
if [ -z "$BANNER" ]; then
  echo "==> предупреждение: не удалось извлечь Ed25519-ключ автоматически."
  echo "    возьми его из баннера первой строки лога запроса вручную:"
  echo "    journalctl --user -u $NAME --no-pager | grep ed25519"
  BANNER="НЕИЗВЕСТНО"
fi

ADDR="ws://$HOST:$PORT/ws"
INVITE="soty://host?addr=$(python3 - <<PYEOF
import urllib.parse; print(urllib.parse.quote("$ADDR", safe=""))
PYEOF
)&pk=$BANNER"

if [ "$INVITE_JSON" -eq 1 ]; then
  python3 - <<PYEOF
import json
print(json.dumps({
  "endpoint": "$ADDR",
  "ed25519_public": "$BANNER",
  "invite": "$INVITE",
}, ensure_ascii=False, indent=2))
PYEOF
else
  cat <<EOF

==> хост развёрнут (${SSH_DEST})
    datadir   $DATA_DIR/host.db
    endpoint  ws://${HOST}:${PORT}/ws
    ed25519   $BANNER
    сервис    systemctl --user status $NAME   (логи: journalctl --user -u $NAME)

    invite для клиентов:
    $INVITE

    вшивай в приложение (см. README, раздел "Полезные dart-define"):
    --dart-define=SOTY_BOOTSTRAP_HOST="$INVITE"
EOF
fi