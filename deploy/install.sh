#!/usr/bin/env bash
# Installs a Soty relay host from a bundle prepared by deploy-host.sh.
#
# Expects, in the same directory: vars.sh, the rendered config file(s) for the
# chosen runtime and — unless SKIP_BIN=1 — a `dtm_host` binary. Runs on the
# target server (locally or over ssh). Not meant to be run by hand.
#
# Works both with and without sudo: vars.sh carries SUDO ('sudo' or '') and
# CAN_ROOT ('1'/'0') as detected by deploy-host.sh on this very target.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/vars.sh"

SUDO="${SUDO-}"
CAN_ROOT="${CAN_ROOT:-0}"

# Over a plain ssh session systemctl/journalctl --user need this to find the
# user's systemd bus; harmless for the other runtimes.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$RUNTIME" in
	systemd-system|supervisor)
		[ "$CAN_ROOT" = "1" ] || die "для $RUNTIME нужен root или passwordless sudo; без sudo: --runtime systemd-user | nohup"
		;;
esac

ensure_user() {
	if id -u "$RUN_USER" >/dev/null 2>&1; then
		return
	fi
	log "создаю системного пользователя $RUN_USER"
	$SUDO useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER" \
		|| log "не удалось создать $RUN_USER — создай вручную и перезапусти"
}

install_bin() {
	if [ "$SKIP_BIN" = "1" ]; then
		log "бинарь не заливаю (--unit-only), беру $BIN как есть"
		[ -f "$BIN" ] || log "предупреждение: $BIN не найден"
		return
	fi
	[ -f "$DIR/dtm_host" ] || die "в пакете нет dtm_host"
	log "ставлю бинарь в $BIN"
	$SUDO install -d -m 0755 "$BIN_DIR"
	$SUDO install -m 0755 "$DIR/dtm_host" "$BIN"
}

# Installs the nginx server{} when we have root/sudo; otherwise drops the file
# in the home dir and prints what to do (shared hosting like dcns.ru, where the
# vhost is owned by the provider).
install_nginx() {
	[ "$NGINX" = "1" ] || return 0
	if [ "$CAN_ROOT" = "1" ]; then
		log "ставлю nginx-конфиг в $NGINX_CONF"
		$SUDO install -d -m 0755 "$(dirname "$NGINX_CONF")"
		$SUDO install -m 0644 "$DIR/soty-server.conf" "$NGINX_CONF"
		if command -v nginx >/dev/null 2>&1; then
			if $SUDO nginx -t; then
				$SUDO nginx -s reload || log "nginx -s reload не удался — перезапусти nginx вручную"
			else
				log "nginx -t не прошёл — конфиг положен, но не активен"
			fi
		fi
		return
	fi
	NGINX_HOME="${HOME}/soty-server.conf"
	log "нет root — кладу nginx-конфиг в $NGINX_HOME"
	log "включи его сам: скопируй в свой server{} / conf.d и перезагрузи nginx"
	install -m 0644 "$DIR/soty-server.conf" "$NGINX_HOME"
}

case "$RUNTIME" in
	systemd-user)
		install_bin
		UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
		mkdir -p "$UNIT_DIR"
		install -m 0644 "$DIR/${NAME}.service" "$UNIT_DIR/${NAME}.service"
		systemctl --user daemon-reload
		systemctl --user enable --now "${NAME}.service"
		install_nginx
		;;
	systemd-system)
		ensure_user
		$SUDO install -d -m 0755 "$BIN_DIR" "$DATA_DIR"
		$SUDO chown -R "${RUN_USER}:${RUN_GROUP}" "$BIN_DIR" "$DATA_DIR"
		install_bin
		$SUDO install -m 0644 "$DIR/${NAME}.service" "/etc/systemd/system/${NAME}.service"
		$SUDO systemctl daemon-reload
		$SUDO systemctl enable --now "${NAME}.service"
		install_nginx
		;;
	supervisor)
		ensure_user
		$SUDO install -d -m 0755 "$BIN_DIR" "$DATA_DIR" "$LOG_DIR"
		$SUDO chown -R "${RUN_USER}:${RUN_GROUP}" "$BIN_DIR" "$DATA_DIR" "$LOG_DIR"
		install_bin
		SUPERVISOR_DIR="/etc/supervisor/conf.d"
		[ -d "$SUPERVISOR_DIR" ] || die "нет $SUPERVISOR_DIR — установи supervisor"
		$SUDO install -m 0644 "$DIR/${NAME}.conf" "$SUPERVISOR_DIR/${NAME}.conf"
		$SUDO supervisorctl reread
		$SUDO supervisorctl update
		$SUDO supervisorctl restart "$NAME" || true
		install_nginx
		;;
	nohup)
		mkdir -p "$BIN_DIR" "$DATA_DIR" "$LOG_DIR"
		install_bin
		install -m 0755 "$DIR/supervise.sh" "$BIN_DIR/supervise.sh"
		install -m 0755 "$DIR/start.sh" "$BIN_DIR/start.sh"
		install -m 0755 "$DIR/stop.sh" "$BIN_DIR/stop.sh"
		install -m 0755 "$DIR/status.sh" "$BIN_DIR/status.sh"
		"$BIN_DIR/start.sh"
		if command -v crontab >/dev/null 2>&1; then
			( crontab -l 2>/dev/null | grep -v "$BIN_DIR/start.sh"; \
			  echo "@reboot $BIN_DIR/start.sh" ) | crontab - \
				|| log "не удалось записать @reboot — добавь '$BIN_DIR/start.sh' в cron вручную"
		else
			log "crontab нет — для автозапуска добавь '$BIN_DIR/start.sh' в автозагрузку вручную"
		fi
		install_nginx
		;;
esac

log "готово (runtime=$RUNTIME, service=$NAME)"
