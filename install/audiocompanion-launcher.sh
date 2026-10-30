#!/bin/sh
# URL-scheme handler for the Audio Companion plugin (Linux).
# Invoked as: audiocompanion-launcher.sh audiocompanion://start | audiocompanion://stop
# Both actions are idempotent. Only the VLC bound to PORT is ever touched.

PORT=${AUDIOCOMPANION_PORT:-9091}
PASS=musescore

action=${1#audiocompanion://}
action=${action%%[/?#]*}

answers() {
    curl -s -m 1 -u ":$PASS" -o /dev/null "http://127.0.0.1:$PORT/requests/status.xml"
}

# PID listening on PORT whose command line is a VLC with that http-port.
vlc_pid() {
    for pid in $(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2); do
        if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "vlc.*--http-port $PORT"; then
            echo "$pid"
        fi
    done
}

case "$action" in
start)
    answers && exit 0
    setsid -f cvlc --extraintf http --http-host 127.0.0.1 --http-port "$PORT" \
        --http-password "$PASS" --no-video --quiet >/dev/null 2>&1 </dev/null
    ;;
stop)
    pids=$(vlc_pid)
    [ -n "$pids" ] && kill $pids
    ;;
*)
    echo "usage: $0 audiocompanion://start|stop" >&2
    exit 2
    ;;
esac
