#!/usr/bin/env bash
# Starts VLC as a headless HTTP server for the Audio Companion plugin.
# Run this once before using the plugin; keep the terminal open (or add & to background it).
#
# Usage: ./start-vlc-server.sh [port]   default port: 9090
#
# In VLC 3.x, --http-password "" disables authentication — the plugin
# connects without credentials. If your VLC version requires a non-empty
# password, pass it as the second argument and set vlcPassword in the
# plugin's settings (not yet exposed in UI).

PORT=${1:-9090}

if ! command -v cvlc &>/dev/null; then
    echo "Error: cvlc not found. Install VLC: sudo apt install vlc"
    exit 1
fi

echo "Starting VLC HTTP server on 127.0.0.1:${PORT} ..."
exec cvlc \
    --intf http \
    --http-host 127.0.0.1 \
    --http-port "$PORT" \
    --http-password "" \
    --no-video \
    --quiet
