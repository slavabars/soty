#!/usr/bin/env bash
# Soty relay installer for Linux.
#
# Detect the distro and architecture, download the current dtm_host release
# and install it as a relay. Works as root (system service) or as a regular
# user (systemd --user or a small supervisor loop).
#
#   sudo ./scripts/install-relay.sh                 # system install
#   ./scripts/install-relay.sh                      # user install
#   sudo ./scripts/install-relay.sh --port 3100 --announce wss://relay.example.com/soty-ws
#   ./scripts/install-relay.sh --version 1.5.0+15
#   sudo ./scripts/install-relay.sh --uninstall [--purge]
#
set -euo pipefail

SERVICE="soty-host"
PORT=3100
LISTEN="0.0.0.0"
ANNOUNCE=""
REL_VERSION=""
URL=""
DB=""
MODE=""
INSTALL_DEPS=1
VERIFY=1
NO_SERVICE=0
UNINSTALL=0
PURGE=0
PEER_ARGS=()

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

usage() {
  cat <<'EOF'
Soty relay installer for Linux.

  sudo ./scripts/install-relay.sh                 # system install (root)
  ./scripts/install-relay.sh                      # user install
  sudo ./scripts/install-relay.sh --port 3100 --announce wss://relay.example.com/soty-ws
  ./scripts/install-relay.sh --version 1.5.0+15
  sudo ./scripts/install-relay.sh --uninstall [--purge]

Флаги:
  --system / --root      установить системно (нужен root)
  --user                 установить в домашний каталог (без root)
  --port N               порт (default: 3100)
  --listen ADDR          адрес bind (default: 0.0.0.0)
  --announce URL         публичный ws://…/ws или wss://… для invite
  --peer SPEC            пир федерации, можно повторять
  --seed SPEC            то же, что --peer (для совместимости)
  --name NAME            имя сервиса (default: soty-host)
  --version X.Y.Z+N      конкретная версия (default: latest)
  --url URL              прямой URL на dtm_host.bin
  --db PATH              путь к host.db
  --no-deps              не устанавливать системные пакеты
  --no-verify            не проверять SHA-256 по GitHub API
  --no-service           только скачать и положить бинарник
  --uninstall            остановить и удалить установку
  --purge                вместе с --uninstall удалить host.db
  -h, --help             эта справка
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --system|--root) MODE=system; shift ;;
    --user) MODE=user; shift ;;
    --port) PORT="$2"; shift 2 ;;
    --listen) LISTEN="$2"; shift 2 ;;
    --announce) ANNOUNCE="$2"; shift 2 ;;
    --peer|--seed) PEER_ARGS+=("--peer" "$2"); shift 2 ;;
    --name) SERVICE="$2"; shift 2 ;;
    --version) REL_VERSION="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --no-deps) INSTALL_DEPS=0; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --no-service) NO_SERVICE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный флаг: $1 (--help)" ;;
  esac
done

[ "$(uname -s)" = "Linux" ] || die "этот установщик только для Linux (macOS: install-relay-macos.sh, Windows: install-relay-windows.ps1)"

if ldd --version 2>&1 | grep -qi musl || ls /lib/ld-musl-* >/dev/null 2>&1; then
  die "Alpine/musl не поддерживается: готовый dtm_host требует glibc. Используй Debian/Ubuntu/RHEL/SUSE/Arch или Docker-вариант"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ;;
  *) die "для $ARCH нет готового бинарника: релиз собирается под Linux x86_64 (на ARM используй Docker-вариант)" ;;
esac

if [ -z "$MODE" ]; then
  if [ "$(id -u)" -eq 0 ]; then MODE=system; else MODE=user; fi
fi
if [ "$MODE" = "system" ] && [ "$(id -u)" -ne 0 ]; then
  die "системная установка требует root: sudo $0 ... или --user"
fi
if [ "$MODE" = "user" ] && [ "$(id -u)" -eq 0 ]; then
  die "--user нельзя запускать от root; запусти без sudo"
fi

# --- distro / package manager ------------------------------------------------
DISTRO="unknown"
PKG=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO="${PRETTY_NAME:-${ID:-unknown}}"
fi
detect_pkg() {
  for p in apt-get dnf yum pacman zypper apk; do
    command -v "$p" >/dev/null 2>&1 && { PKG="$p"; return; }
  done
}
detect_pkg

sqlite_lib_present() {
  for d in /lib /usr/lib /lib64 /usr/lib64 /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do
    [ -e "$d/libsqlite3.so.0" ] && return 0
  done
  command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q 'libsqlite3\.so\.0' && return 0
  return 1
}

sqlite_pkg() {
  case "$PKG" in
    apt-get) echo "libsqlite3-0" ;;
    dnf|yum) echo "sqlite-libs" ;;
    pacman) echo "sqlite" ;;
    zypper) echo "sqlite3" ;;
    apk) echo "sqlite-libs" ;;
    *) echo "libsqlite3" ;;
  esac
}

install_deps() {
  [ "$INSTALL_DEPS" -eq 1 ] || return 0
  [ "$MODE" = "system" ] || return 0
  local libs
  libs="$(sqlite_pkg) ca-certificates"
  command -v curl >/dev/null 2>&1 || libs="$libs curl"
  log "устанавливаю зависимости: $libs"
  case "$PKG" in
    apt-get) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $libs ;;
    dnf) dnf install -y $libs ;;
    yum) yum install -y $libs ;;
    pacman) pacman -Sy --noconfirm $libs ;;
    zypper) zypper --non-interactive install $libs ;;
    apk) apk add --no-cache $libs ;;
    *) die "не знаю, как ставить пакеты в $DISTRO; поставь libsqlite3 вручную" ;;
  esac
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  install_deps
fi
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "нужен curl или wget"

if ! sqlite_lib_present; then
  if [ "$MODE" = "system" ] && [ "$INSTALL_DEPS" -eq 1 ]; then
    install_deps
  fi
  sqlite_lib_present || die "нет libsqlite3. Установи: $PKG install $(sqlite_pkg) (или повтори с sudo)"
fi

# --- paths -------------------------------------------------------------------
if [ "$MODE" = "system" ]; then
  BIN="/usr/local/bin/dtm_host"
  DATA="/var/lib/soty"
  CONF_DIR="/etc/soty"
  LOG="$DATA/host.log"
  [ -n "$DB" ] || DB="$DATA/host.db"
  UNIT_DIR="/etc/systemd/system"
  UNIT="$UNIT_DIR/$SERVICE.service"
else
  BIN="$HOME/.local/bin/dtm_host"
  DATA="${XDG_DATA_HOME:-$HOME/.local/share}/soty"
  CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/soty"
  LOG="$DATA/host.log"
  [ -n "$DB" ] || DB="$DATA/host.db"
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  UNIT="$UNIT_DIR/$SERVICE.service"
fi
DB_DIR="$(dirname "$DB")"
SUPERVISE="$DATA/supervise.sh"
START="$DATA/start.sh"
STOP="$DATA/stop.sh"
STATUS="$DATA/status.sh"

service_logs() {
  if [ -f "$LOG" ]; then cat "$LOG"; fi
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$MODE" = "system" ]; then
      journalctl -u "$SERVICE" --no-pager -n 300 2>/dev/null || true
    else
      journalctl --user -u "$SERVICE" --no-pager -n 300 2>/dev/null || true
    fi
  fi
}

service_active() {
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$MODE" = "system" ]; then
      systemctl is-active --quiet "$SERVICE" 2>/dev/null && return 0
    else
      systemctl --user is-active --quiet "$SERVICE" 2>/dev/null && return 0
    fi
  fi
  pgrep -f "$BIN" >/dev/null 2>&1
}

stop_fallback() {
  [ -f "$STOP" ] && bash "$STOP" >/dev/null 2>&1 || true
  pkill -f "$SUPERVISE" 2>/dev/null || true
  pkill -f "$BIN" 2>/dev/null || true
}

uninstall() {
  log "удаляю $SERVICE"
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$MODE" = "system" ]; then
      systemctl disable --now "$SERVICE" 2>/dev/null || true
    else
      systemctl --user disable --now "$SERVICE" 2>/dev/null || true
    fi
    rm -f "$UNIT"
    systemctl daemon-reload 2>/dev/null || true
  fi
  stop_fallback
  if command -v crontab >/dev/null 2>&1; then
    ( crontab -l 2>/dev/null | grep -v "$START" ) | crontab - 2>/dev/null || true
  fi
  rm -f "$BIN" "$SUPERVISE" "$START" "$STOP" "$STATUS"
  if [ "$PURGE" -eq 1 ]; then
    log "удаляю данные: $DATA"
    rm -rf "$DATA" "$CONF_DIR"
  else
    echo "    данные сохранены: $DATA (удалить: --purge)"
  fi
  echo "==> удалено"
  exit 0
}

[ "$UNINSTALL" -eq 1 ] && uninstall

# --- download ----------------------------------------------------------------
command -v curl >/dev/null 2>&1 && FETCH="curl" || FETCH="wget"
fetch() {
  local url="$1" dest="$2"
  if [ "$FETCH" = "curl" ]; then
    curl -fL --retry 3 --connect-timeout 15 -o "$dest" "$url"
  else
    wget -q -O "$dest" --timeout=30 --tries=3 "$url"
  fi
}

TAG=""
if [ -n "$REL_VERSION" ]; then
  TAG="v${REL_VERSION#v}"
fi
if [ -z "$URL" ]; then
  if [ -n "$TAG" ]; then
    ENC_TAG="$(printf '%s' "$TAG" | sed 's/+/%2B/g')"
    URL="https://github.com/slavabars/soty/releases/download/$ENC_TAG/dtm_host.bin"
    API="https://api.github.com/repos/slavabars/soty/releases/tags/$ENC_TAG"
  else
    URL="https://github.com/slavabars/soty/releases/latest/download/dtm_host.bin"
    API="https://api.github.com/repos/slavabars/soty/releases/latest"
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log "скачиваю $URL"
fetch "$URL" "$TMP/dtm_host" || die "не удалось скачать бинарник"
[ -s "$TMP/dtm_host" ] || die "скачался пустой файл"

MAGIC="$(head -c 4 "$TMP/dtm_host" | od -An -tx1 | tr -d ' \n')"
[ "$MAGIC" = "7f454c46" ] || die "это не ELF-бинарник Linux (получен не тот файл?)"

if [ "$VERIFY" -eq 1 ]; then
  DIGEST=""
  if [ -n "${API:-}" ]; then
    fetch "$API" "$TMP/release.json" 2>/dev/null || true
    if [ -s "$TMP/release.json" ]; then
      if command -v python3 >/dev/null 2>&1; then
        DIGEST="$(python3 - "$TMP/release.json" <<'PY' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1]))
for a in d.get('assets', []):
    if a.get('name') == 'dtm_host.bin':
        print((a.get('digest') or '').replace('sha256:', ''))
        break
PY
)"
      fi
      if [ -z "$DIGEST" ]; then
        DIGEST="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"dtm_host.bin"[^}]*"digest"[[:space:]]*:[[:space:]]*"sha256:\([0-9a-f]*\)".*/\1/p' "$TMP/release.json" | head -1)"
      fi
    fi
  fi
  if [ -n "$DIGEST" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      ACTUAL="$(sha256sum "$TMP/dtm_host" | awk '{print $1}')"
    else
      ACTUAL="$(shasum -a 256 "$TMP/dtm_host" | awk '{print $1}')"
    fi
    [ "$ACTUAL" = "$DIGEST" ] || die "SHA-256 не совпал: $ACTUAL != $DIGEST"
    log "SHA-256 подтверждён: $ACTUAL"
  else
    echo "warning: не удалось получить SHA-256 из GitHub API, проверка пропущена" >&2
  fi
fi

# --- install binary ----------------------------------------------------------
make_dir() { mkdir -p "$1" && chmod "$2" "$1"; }
put_bin() {
  cp -f "$1" "$2.new"
  chmod 0755 "$2.new"
  mv -f "$2.new" "$2"
}

group_exists() {
  getent group soty >/dev/null 2>&1 || grep -q '^soty:' /etc/group 2>/dev/null
}
if [ "$MODE" = "system" ]; then
  if ! group_exists; then
    if command -v groupadd >/dev/null 2>&1; then
      groupadd --system soty 2>/dev/null || true
    elif command -v addgroup >/dev/null 2>&1; then
      addgroup -S soty 2>/dev/null || true
    fi
  fi
  if ! id -u soty >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
      useradd --system --gid soty --home "$DATA" --shell /usr/sbin/nologin soty 2>/dev/null || true
    elif command -v adduser >/dev/null 2>&1; then
      adduser -S -D -H -h "$DATA" -s /sbin/nologin -G soty soty 2>/dev/null || true
    fi
  fi
  id -u soty >/dev/null 2>&1 || die "не удалось создать пользователя soty"
  make_dir "$DATA" 0750
  make_dir "$CONF_DIR" 0750
  chown soty:soty "$DATA" 2>/dev/null || die "не удалось назначить владельца $DATA"
  make_dir "$DB_DIR" 0750
  chown soty:soty "$DB_DIR" 2>/dev/null || true
  put_bin "$TMP/dtm_host" "$BIN"
  chown root:root "$BIN"
else
  make_dir "$HOME/.local/bin" 0755
  make_dir "$DATA" 0700
  make_dir "$CONF_DIR" 0700
  make_dir "$DB_DIR" 0700
  put_bin "$TMP/dtm_host" "$BIN"
fi

HOST_ARGS=(--db "$DB" --listen "$LISTEN" --port "$PORT")
[ -n "$ANNOUNCE" ] && HOST_ARGS+=(--announce "$ANNOUNCE")
HOST_ARGS+=("${PEER_ARGS[@]}")

ADDR="${ANNOUNCE:-ws://127.0.0.1:$PORT/ws}"
{
  echo "# Soty relay configuration (generated by install-relay.sh)"
  echo "SOTY_LISTEN=$LISTEN"
  echo "SOTY_PORT=$PORT"
  echo "SOTY_ANNOUNCE=$ADDR"
  echo "SOTY_DB=$DB"
  echo "SOTY_BIN=$BIN"
} > "$CONF_DIR/relay.conf"

if [ "$NO_SERVICE" -eq 0 ]; then
  if command -v systemctl >/dev/null 2>&1; then
    unit_quote() {
      printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g')"
    }
    EXEC=""
    for a in "${HOST_ARGS[@]}"; do EXEC="$EXEC $(unit_quote "$a")"; done
    mkdir -p "$UNIT_DIR"
    if [ "$MODE" = "system" ]; then
      cat > "$UNIT" <<EOF
[Unit]
Description=Soty relay host + tracker
After=network-online.target
Wants=network-online.target

[Service]
User=soty
Group=soty
ExecStart=$BIN$EXEC
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$DATA $DB_DIR

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable "$SERVICE"
      systemctl restart "$SERVICE"
    else
      cat > "$UNIT" <<EOF
[Unit]
Description=Soty relay host + tracker
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN$EXEC
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
      if ! ( systemctl --user daemon-reload && systemctl --user enable "$SERVICE" && systemctl --user restart "$SERVICE" ) 2>/dev/null; then
        echo "warning: systemd --user недоступен, запускаю через supervisor" >&2
        rm -f "$UNIT"
        NO_SERVICE=2
      fi
    fi
  else
    NO_SERVICE=2
  fi
fi

if [ "$NO_SERVICE" = "2" ]; then
  {
    echo '#!/usr/bin/env bash'
    echo 'set -u'
    echo "LOG=$(printf '%q' "$LOG")"
    echo 'while true; do'
    printf '  '
    printf '%q' "$BIN"
    for a in "${HOST_ARGS[@]}"; do printf ' %q' "$a"; done
    echo ' >> "$LOG" 2>&1'
    echo '  echo "--- dtm_host exited rc=$? at $(date -Is), restarting in 5s ---" >> "$LOG"'
    echo '  sleep 5'
    echo 'done'
  } > "$SUPERVISE"
  cat > "$START" <<EOF
#!/usr/bin/env bash
pkill -f "$SUPERVISE" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
sleep 2
nohup setsid "$SUPERVISE" >/dev/null 2>&1 &
sleep 4
pgrep -af "$BIN" || echo "NOT RUNNING"
EOF
  cat > "$STOP" <<EOF
#!/usr/bin/env bash
pkill -f "$SUPERVISE" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
sleep 2
if pgrep -f "$BIN" >/dev/null 2>&1; then echo "still running"; else echo "stopped"; fi
EOF
  cat > "$STATUS" <<EOF
#!/usr/bin/env bash
pgrep -af "$BIN" || echo "NOT RUNNING"
echo "--- log tail ---"
tail -n 20 "$LOG" 2>/dev/null || echo "no log yet"
EOF
  chmod 700 "$SUPERVISE" "$START" "$STOP" "$STATUS"
  if [ "$MODE" = "system" ]; then
    chown -R soty:soty "$DATA" 2>/dev/null || true
    chmod 755 "$DATA"
    # supervisor runs as root here so the binary can bind a privileged port
  fi
  bash "$START" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    ( crontab -l 2>/dev/null | grep -v "$START"; echo "@reboot $START" ) | crontab - 2>/dev/null || true
  fi
fi

# --- wait and print invite ---------------------------------------------------
ED=""
for _ in $(seq 1 20); do
  ED="$(service_logs | grep -Eo 'ed25519 [0-9a-f]{64}' | tail -1 | awk '{print $2}' || true)"
  [ -n "$ED" ] && break
  sleep 1
done

urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
  elif command -v jq >/dev/null 2>&1; then
    jq -rn --arg v "$1" '$v|@uri'
  else
    printf '%s' "$1" | sed 's/:/%3A/g; s#/#%2F#g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g'
  fi
}

INVITE=""
[ -n "$ED" ] && INVITE="soty://host?addr=$(urlencode "$ADDR")&pk=$ED"

echo
echo "==> Soty relay установлен ($MODE, $DISTRO)"
echo "    бинарник  $BIN"
echo "    база      $DB"
echo "    endpoint  $ADDR"
echo "    сервис    $SERVICE"
if [ "$NO_SERVICE" = "2" ]; then
  echo "    запуск    $START (лог: $LOG)"
  echo "    стоп      $STOP"
else
  if [ "$MODE" = "system" ]; then
    echo "    статус    systemctl status $SERVICE"
    echo "    лог       journalctl -u $SERVICE -f"
  else
    echo "    статус    systemctl --user status $SERVICE"
    echo "    лог       journalctl --user -u $SERVICE -f"
    echo "    автозапуск: loginctl enable-linger $USER"
  fi
fi
if [ -n "$ED" ]; then
  echo "    ed25519   $ED"
  echo
  echo "    invite для клиентов:"
  echo "    $INVITE"
else
  echo "    ed25519   ещё не найден в логе; проверь: $STATUS"
fi
echo
echo "    не удаляй $DB: в нём Ed25519-идентичность и пины клиентов"
