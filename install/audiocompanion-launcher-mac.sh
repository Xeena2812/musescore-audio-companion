#!/bin/sh
# URL-scheme handler body for the Audio Companion plugin (macOS).
# Called by the AudioCompanion.app wrapper with audiocompanion://start|stop.
PORT=${AUDIOCOMPANION_PORT:-9091}
PASS=musescore
VLC=/Applications/VLC.app/Contents/MacOS/VLC

action=${1#audiocompanion://}
action=${action%%[/?#]*}

case "$action" in
start)
    curl -s -m 1 -u ":$PASS" -o /dev/null "http://127.0.0.1:$PORT/requests/status.xml" && exit 0
    [ -x "$VLC" ] || exit 1
    nohup "$VLC" -I dummy --extraintf http --http-host 127.0.0.1 --http-port "$PORT" \
        --http-password "$PASS" --no-video --quiet >/dev/null 2>&1 </dev/null &
    ;;
stop)
    # Only a VLC listening on our port.
    for pid in $(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null); do
        ps -p "$pid" -o command= | grep -q "http-port $PORT" && kill "$pid"
    done
    ;;
esac
