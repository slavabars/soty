#!/usr/bin/env bash
# Soty relay host installer / updater.
#
# Deploys dtm_host (relay + tracker) and runs it under one of four runtimes:
#   systemd-user   — user service (no root, starts at login)      [default]
#   systemd-system — system service under a dedicated user (root)
#   supervisor     — supervisord program (root)
#   nohup          — shell supervisor + @reboot cron (no root, no systemd)
# Optionally installs an nginx server{} block for a WebSocket reverse proxy.
#
# The binary is not shipped in this repository: download dtm_host.bin from the
# GitHub release (https://github.com/slavabars/soty/releases) or build it
# yourself, and pass it with --app.
#
# Run with --help for the full option list.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "нужен '$1' в PATH"; }

usage() {
	cat <<'EOF'
Soty relay host installer.

Разворачивает dtm_host (relay + tracker) и запускает его одним из четырёх
способов: systemd --user, systemd (системный), supervisor или nohup + cron
@reboot. Опционально ставит server{} nginx для WebSocket-прокси.

Подключение
  --ssh USER@HOST       поставить на удалённый сервер по ssh (по умолчанию локально)
  --ssh-port N          порт ssh (по умолчанию 22)

Пути
  --app PATH            локальный бинарь dtm_host (по умолчанию ./dtm_host.bin)
  --bindir DIR          каталог бинаря на сервере (по умолчанию ~/local)
  --datadir DIR         каталог host.db на сервере (по умолчанию ~/soty)
  --unit-only           не заливать бинарь (взять уже лежащий на сервере)

Сеть
  --listen IP           адрес привязки (по умолчанию 0.0.0.0)
  --port PORT           порт привязки (по умолчанию 3100)
  --announce URL        публичный ws(s):// для баннера и федерации

Федерация (флаги можно повторять)
  --peer SPEC           пир: 'ws://host:3100/ws|ed25519hex'
  --seed SPEC           как --peer, плюс принять его сеть как свою

Запуск
  --runtime MODE        auto | systemd-user | systemd-system | supervisor | nohup
                        (по умолчанию systemd-user; auto сам выберет по правам и
                        наличию systemd)
  --sudo                требовать установку через sudo/root
  --no-sudo             запретить sudo (только user-варианты)
  --name NAME           имя сервиса/программы (по умолчанию soty-host)
  --user USER           системный пользователь (для systemd-system/supervisor)
  --no-restart          не перезапускать автоматически

Nginx
  --nginx               поставить server{} с прокси
  --nginx-path PATH     публичный путь (по умолчанию /soty-ws)
  --nginx-server-name N server_name (по умолчанию хост из --announce)
  --nginx-conf FILE     куда положить (по умолчанию /etc/nginx/conf.d/soty-ws.conf)

Вывод
  --print-config        напечатать отрендеренные конфиги и выйти (без изменений)
  --invite-json         вывести итоговый invite как JSON
  --check               только проверить запущенный хост (без изменений)
  --expect-ed HEX       ожидаемый Ed25519 (для --check)
  --help

Примеры
  # локально, systemd --user, ws:// на порту 3100
  ./deploy-host.sh --app ./dtm_host.bin --announce ws://relay.example.com:3100/ws

  # удалённо, системный systemd, за nginx
  ./deploy-host.sh --ssh dtm@relay.example.com --runtime systemd-system \
      --nginx --announce wss://relay.example.com/soty-ws

  # хостинг без root: nohup + cron, слушать только localhost
  ./deploy-host.sh --runtime nohup --listen 127.0.0.1
EOF
	exit 0
}

SSH_TARGET=""
SSH_PORT=22
APP="./dtm_host.bin"
BINDIR=""
DATADIR=""
UNIT_ONLY=0
LISTEN="0.0.0.0"
PORT=3100
ANNOUNCE=""
PEERS=()
SEEDS=()
RUNTIME="systemd-user"
SUDO_MODE="auto"
NAME="soty-host"
RUN_USER="soty"
RESTART="on-failure"
NGINX=0
NGINX_PATH="/soty-ws"
NGINX_SERVER_NAME=""
NGINX_CONF="/etc/nginx/conf.d/soty-ws.conf"
PRINT_CONFIG=0
INVITE_JSON=0
CHECK=0
EXPECT_ED=""

while [ $# -gt 0 ]; do
	case "$1" in
		--ssh) SSH_TARGET="$2"; shift 2;;
		--ssh-port) SSH_PORT="$2"; shift 2;;
		--app) APP="$2"; shift 2;;
		--bindir) BINDIR="$2"; shift 2;;
		--datadir) DATADIR="$2"; shift 2;;
		--unit-only) UNIT_ONLY=1; shift;;
		--listen) LISTEN="$2"; shift 2;;
		--port) PORT="$2"; shift 2;;
		--announce) ANNOUNCE="$2"; shift 2;;
		--peer) PEERS+=("$2"); shift 2;;
		--seed) SEEDS+=("$2"); shift 2;;
		--runtime) RUNTIME="$2"; shift 2;;
		--sudo) SUDO_MODE="yes"; shift;;
		--no-sudo) SUDO_MODE="no"; shift;;
		--name) NAME="$2"; shift 2;;
		--user) RUN_USER="$2"; shift 2;;
		--no-restart) RESTART="no"; shift;;
		--nginx) NGINX=1; shift;;
		--nginx-path) NGINX_PATH="/${2#/}"; shift 2;;
		--nginx-server-name) NGINX_SERVER_NAME="$2"; shift 2;;
		--nginx-conf) NGINX_CONF="$2"; shift 2;;
		--print-config) PRINT_CONFIG=1; shift;;
		--invite-json) INVITE_JSON=1; shift;;
		--check) CHECK=1; shift;;
		--expect-ed) EXPECT_ED="$2"; shift 2;;
		--help|-h) usage;;
		*) die "неизвестный флаг: $1 (--help)";;
	esac
done

case "$RUNTIME" in
	auto|systemd-user|systemd-system|supervisor|nohup) ;;
	*) die "--runtime: ожидается auto|systemd-user|systemd-system|supervisor|nohup, а не '$RUNTIME'";;
esac
case "$PORT" in *[!0-9]*|"") die "--port: нужно число, а не '$PORT'";; esac

# Values end up inside single quotes in the rendered configs: forbid '.
for v in "$ANNOUNCE" ${PEERS[@]+"${PEERS[@]}"} ${SEEDS[@]+"${SEEDS[@]}"}; do
	[ -n "$v" ] || continue
	case "$v" in *"'"*) die "значение не должно содержать одинарную кавычку: $v";; esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$CHECK" -eq 1 ]; then
	[ -n "$ANNOUNCE" ] || die "--check требует --announce URL"
	need python3
	echo "==> проверяю $ANNOUNCE ..."
	python3 "$HERE/host_probe.py" "$ANNOUNCE" ${EXPECT_ED:+"$EXPECT_ED"}
	exit 0
fi

if [ "$UNIT_ONLY" -eq 0 ] && [ "$PRINT_CONFIG" -eq 0 ]; then
	[ -f "$APP" ] || die "нет бинаря: $APP (скачай dtm_host.bin из Releases или передай --app)"
fi

DEF_HOST="localhost"
[ -n "$SSH_TARGET" ] && DEF_HOST="${SSH_TARGET#*@}"
[ -z "$ANNOUNCE" ] && ANNOUNCE="ws://${DEF_HOST}:${PORT}/ws"

# --- remote HOME (needed to resolve ~-based defaults before rendering) ------
remote() { ssh -p "$SSH_PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"; }
run_target() { if [ -n "$SSH_TARGET" ]; then remote "$1"; else bash -c "$1"; fi; }
TARGET_HOME="$HOME"
if [ -n "$SSH_TARGET" ]; then
	need ssh
	need scp
	echo "==> ssh-доступ к ${SSH_TARGET} ..."
	remote 'true' || die "ssh не работает до $SSH_TARGET (пароль/ключ?)"
	TARGET_HOME="$(remote 'printf %s "$HOME"')"
	[ -n "$TARGET_HOME" ] || die "не удалось определить HOME на сервере"
fi

# --- capability probe: root/sudo, systemd, systemd --user --------------------
# The scripts must work both with and without sudo (e.g. the dcns.ru box: no
# root, no systemd — shell supervisor + @reboot cron behind the provider's
# nginx). So we detect what the target offers and pick accordingly.
read -r T_ROOT T_SUDO T_SYSD T_USYSD <<EOF
$(run_target '
	uid=$(id -u)
	if [ "$uid" -eq 0 ]; then root=1; sudo_ok=1;
	elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then root=0; sudo_ok=1;
	else root=0; sudo_ok=0; fi
	[ -d /run/systemd/system ] && sysd=1 || sysd=0
	if command -v systemctl >/dev/null 2>&1 && XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user show-environment >/dev/null 2>&1; then usysd=1; else usysd=0; fi
	printf "%s %s %s %s\n" "$root" "$sudo_ok" "$sysd" "$usysd"
')
EOF
[ -n "$T_ROOT" ] || die "не удалось определить права на цели"

CAN_ROOT=0
SUDO=""
if [ "$SUDO_MODE" = "no" ]; then
	CAN_ROOT=0
elif [ "$T_ROOT" = "1" ]; then
	CAN_ROOT=1
elif [ "$T_SUDO" = "1" ]; then
	CAN_ROOT=1
	SUDO="sudo"
fi

if [ "$RUNTIME" = "auto" ]; then
	if [ "$CAN_ROOT" = "1" ] && [ "$T_SYSD" = "1" ]; then
		RUNTIME="systemd-system"
	elif [ "$T_USYSD" = "1" ]; then
		RUNTIME="systemd-user"
	else
		RUNTIME="nohup"
	fi
	echo "==> --runtime auto: выбран $RUNTIME (root=$T_ROOT sudo=$T_SUDO systemd=$T_SYSD user-systemd=$T_USYSD)"
fi

case "$RUNTIME" in
	systemd-system|supervisor)
		[ "$CAN_ROOT" = "1" ] || die "для --runtime $RUNTIME нужен root или passwordless sudo; без sudo используйте --runtime systemd-user или --runtime nohup"
		;;
esac

case "$RUNTIME" in
	systemd-system|supervisor)
		: "${BINDIR:=/opt/soty}"
		: "${DATADIR:=/var/lib/soty}"
		;;
	*)
		: "${BINDIR:=$TARGET_HOME/local}"
		: "${DATADIR:=$TARGET_HOME/soty}"
		;;
esac
LOG_DIR="$DATADIR"
BIN="$BINDIR/dtm_host"
DB="$DATADIR/host.db"
RUN_GROUP="$RUN_USER"
AUTORESTART="true"
[ "$RESTART" = "no" ] && AUTORESTART="false"

UPSTREAM_HOST="$LISTEN"
[ "$LISTEN" = "0.0.0.0" ] && UPSTREAM_HOST="127.0.0.1"
UPSTREAM="${UPSTREAM_HOST}:${PORT}"
SCHEME="http"
case "$ANNOUNCE" in wss://*) SCHEME="https";; esac
[ -z "$NGINX_SERVER_NAME" ] && NGINX_SERVER_NAME="$(printf '%s' "$ANNOUNCE" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')"
[ -z "$NGINX_SERVER_NAME" ] && NGINX_SERVER_NAME="$DEF_HOST"

EXTRA=""
[ -n "$ANNOUNCE" ] && EXTRA+=" --announce '$ANNOUNCE'"
for p in ${PEERS[@]+"${PEERS[@]}"}; do EXTRA+=" --peer '$p'"; done
for s in ${SEEDS[@]+"${SEEDS[@]}"}; do EXTRA+=" --seed '$s'"; done

# --- render templates -------------------------------------------------------
declare -A VARS=(
	[NAME]="$NAME" [BIN]="$BIN" [DB]="$DB" [BINDIR]="$BINDIR" [DATADIR]="$DATADIR"
	[LOGDIR]="$LOG_DIR" [LISTEN]="$LISTEN" [PORT]="$PORT" [EXTRA]="$EXTRA"
	[USER]="$RUN_USER" [GROUP]="$RUN_GROUP" [RESTART]="$RESTART"
	[AUTORESTART]="$AUTORESTART" [NGINX_PATH]="$NGINX_PATH" [UPSTREAM]="$UPSTREAM"
	[SCHEME]="$SCHEME" [SERVER_NAME]="$NGINX_SERVER_NAME"
)

render() { # render <template> <out>
	local out k v
	out="$(cat "$1")"
	for k in "${!VARS[@]}"; do
		v="${VARS[$k]//\\/\\\\}"
		v="${v//&/\\&}"
		v="${v//|/\\|}"
		out="$(printf '%s' "$out" | sed "s|@@${k}@@|${v}|g")"
	done
	printf '%s\n' "$out" >"$2"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/soty-deploy.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PKG="$TMP/pkg"
mkdir -p "$PKG"

case "$RUNTIME" in
	systemd-user) render "$HERE/systemd/soty-host.user.service" "$PKG/${NAME}.service";;
	systemd-system) render "$HERE/systemd/soty-host.system.service" "$PKG/${NAME}.service";;
	supervisor) render "$HERE/supervisor/soty-host.conf" "$PKG/${NAME}.conf";;
	nohup)
		render "$HERE/nohup/supervise.sh" "$PKG/supervise.sh"
		render "$HERE/nohup/start.sh" "$PKG/start.sh"
		render "$HERE/nohup/stop.sh" "$PKG/stop.sh"
		render "$HERE/nohup/status.sh" "$PKG/status.sh"
		;;
esac
if [ "$NGINX" -eq 1 ]; then
	render "$HERE/nginx/soty-server.conf" "$PKG/soty-server.conf"
fi

SKIP_BIN=0
[ "$UNIT_ONLY" -eq 1 ] && SKIP_BIN=1
[ "$PRINT_CONFIG" -eq 1 ] && SKIP_BIN=1

cat >"$PKG/vars.sh" <<EOF
# generated by deploy-host.sh — sourced by install.sh
RUNTIME='$RUNTIME'
NAME='$NAME'
RUN_USER='$RUN_USER'
RUN_GROUP='$RUN_GROUP'
BIN_DIR='$BINDIR'
DATA_DIR='$DATADIR'
LOG_DIR='$LOG_DIR'
BIN='$BIN'
DB='$DB'
LISTEN='$LISTEN'
PORT='$PORT'
ANNOUNCE='$ANNOUNCE'
RESTART='$RESTART'
AUTORESTART='$AUTORESTART'
SKIP_BIN='$SKIP_BIN'
NGINX='$NGINX'
NGINX_PATH='$NGINX_PATH'
NGINX_CONF='$NGINX_CONF'
UPSTREAM='$UPSTREAM'
SUDO='$SUDO'
CAN_ROOT='$CAN_ROOT'
EOF
cp "$HERE/install.sh" "$PKG/install.sh"
# dtm_host is placed next to install.sh; skipped when --unit-only.
[ "$SKIP_BIN" -eq 0 ] && cp "$APP" "$PKG/dtm_host"

if [ "$PRINT_CONFIG" -eq 1 ]; then
	echo "### vars.sh"; cat "$PKG/vars.sh"
	for f in "$PKG"/*.service "$PKG"/*.conf "$PKG"/supervise.sh "$PKG"/start.sh "$PKG"/stop.sh "$PKG"/status.sh; do
		[ -f "$f" ] || continue
		echo "### $(basename "$f")"; cat "$f"
	done
	exit 0
fi

# --- install ----------------------------------------------------------------
if [ -n "$SSH_TARGET" ]; then
	echo "==> копирую пакет на ${SSH_TARGET}:~/.soty-deploy ..."
	tar -C "$PKG" -czf - . | remote 'rm -rf "$HOME/.soty-deploy" && mkdir -p "$HOME/.soty-deploy" && tar -xzf - -C "$HOME/.soty-deploy"'
	echo "==> запускаю install.sh (runtime=$RUNTIME) ..."
	remote 'bash "$HOME/.soty-deploy/install.sh"'
	remote 'rm -rf "$HOME/.soty-deploy"' || true
else
	echo "==> локальная установка (runtime=$RUNTIME) ..."
	bash "$PKG/install.sh"
fi

# --- report -----------------------------------------------------------------
# Read the host's Ed25519 identity from the service log on the target itself.
urlencode() {
	local s="$1" out="" c i
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
			[a-zA-Z0-9.~_-]) out+="$c";;
			*) out+="$(printf '%%%02X' "'$c")";;
		esac
	done
	printf '%s' "$out"
}

sleep 3
ED=""
case "$RUNTIME" in
	systemd-user) ED="$(run_target "XDG_RUNTIME_DIR=/run/user/\$(id -u) journalctl --user -u '$NAME' --no-pager -n 200 2>/dev/null | grep -Eo 'ed25519 [0-9a-f]{64}' | tail -1 | awk '{print \$2}'")";;
	systemd-system) ED="$(run_target "journalctl -u '$NAME' --no-pager -n 200 2>/dev/null | grep -Eo 'ed25519 [0-9a-f]{64}' | tail -1 | awk '{print \$2}'")";;
	supervisor|nohup) ED="$(run_target "grep -Eo 'ed25519 [0-9a-f]{64}' '$LOG_DIR/host.log' 2>/dev/null | tail -1 | awk '{print \$2}'")";;
esac

ADDR="$ANNOUNCE"
INVITE="soty://host?addr=$(urlencode "$ADDR")&pk=$ED"

if [ "$INVITE_JSON" -eq 1 ]; then
	cat <<JSON
{
  "runtime": "$RUNTIME",
  "name": "$NAME",
  "endpoint": "$ADDR",
  "db": "$DB",
  "ed25519_public": "${ED:-UNKNOWN}",
  "invite": "$INVITE"
}
JSON
	exit 0
fi

cat <<EOF

==> хост развёрнут (runtime=$RUNTIME, service=$NAME)
    endpoint  $ADDR
    db        $DB
    ed25519   ${ED:-НЕИЗВЕСТНО (смотри лог сервиса)}
    invite    $INVITE
EOF
if [ "$RUNTIME" = "systemd-user" ]; then
	echo "    логи      journalctl --user -u $NAME"
	echo "    restart   systemctl --user restart $NAME"
elif [ "$RUNTIME" = "systemd-system" ]; then
	echo "    логи      journalctl -u $NAME"
	echo "    restart   sudo systemctl restart $NAME"
elif [ "$RUNTIME" = "supervisor" ]; then
	echo "    логи      $LOG_DIR/host.log"
	echo "    restart   sudo supervisorctl restart $NAME"
else
	echo "    логи      $LOG_DIR/host.log"
	echo "    restart   $BINDIR/start.sh"
fi
