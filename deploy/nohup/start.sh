#!/usr/bin/env bash
# Start (or restart) the Soty relay under the shell supervisor.
set -u
SUP_PIDFILE="@@LOGDIR@@/supervise.pid"
mkdir -p "@@LOGDIR@@"
# Stop a previous supervisor (and its binary) before starting a fresh one.
if [ -f "$SUP_PIDFILE" ]; then
	old="$(cat "$SUP_PIDFILE" 2>/dev/null || true)"
	[ -n "$old" ] && { kill -TERM "-$old" 2>/dev/null || kill -TERM "$old" 2>/dev/null || true; }
fi
pkill -f '^@@BIN@@ ' 2>/dev/null || true
sleep 2
rm -f "$SUP_PIDFILE"
setsid "@@BINDIR@@/supervise.sh" >/dev/null 2>&1 &
sleep 3
pgrep -f '^@@BIN@@ ' || echo "  NOT RUNNING"
