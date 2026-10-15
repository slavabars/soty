#!/usr/bin/env bash
# Soty relay shell supervisor: keeps dtm_host running without systemd/root.
# Started by start.sh (and by @reboot cron); restarts the binary after a crash.
# Writes its PID so stop.sh can kill the whole process group cleanly.
cd "@@BINDIR@@" || exit 1
PIDFILE="@@LOGDIR@@/supervise.pid"
mkdir -p "@@LOGDIR@@"
echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
while true; do
	@@BIN@@ --db @@DB@@ --listen @@LISTEN@@ --port @@PORT@@@@EXTRA@@ >>"@@LOGDIR@@/host.log" 2>&1
	echo "--- dtm_host exited rc=$? at $(date -Is), restart in 5s ---" >>"@@LOGDIR@@/host.log"
	sleep 5
done
