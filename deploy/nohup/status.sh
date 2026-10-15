#!/usr/bin/env bash
# Soty relay status + log tail.
SUP_PIDFILE="@@LOGDIR@@/supervise.pid"
if [ -f "$SUP_PIDFILE" ]; then
	echo "supervisor pid $(cat "$SUP_PIDFILE" 2>/dev/null)"
else
	echo "no supervisor pidfile"
fi
pgrep -af '^@@BIN@@ ' || echo "NOT RUNNING"
echo "--- log tail ---"
tail -n 20 "@@LOGDIR@@/host.log" 2>/dev/null || echo "no log yet"
