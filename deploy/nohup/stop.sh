#!/usr/bin/env bash
# Stop the Soty relay and its shell supervisor.
set -u
SUP_PIDFILE="@@LOGDIR@@/supervise.pid"
if [ -f "$SUP_PIDFILE" ]; then
	old="$(cat "$SUP_PIDFILE" 2>/dev/null || true)"
	[ -n "$old" ] && { kill -TERM "-$old" 2>/dev/null || kill -TERM "$old" 2>/dev/null || true; }
fi
pkill -f '^@@BIN@@ ' 2>/dev/null || true
sleep 2
rm -f "$SUP_PIDFILE"
if pgrep -f '^@@BIN@@ ' >/dev/null; then echo "  still running"; else echo "stopped"; fi
