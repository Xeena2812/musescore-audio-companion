#!/usr/bin/env bash
# Starts VLC as a headless HTTP server for the Audio Companion plugin.
# Run this once before using the plugin; keep the terminal open.
#
# Usage: ./start-vlc-server.sh [port [password]]
#   defaults: port=9090  password=musescore

PORT=${1:-9090}
PASS=${2:-musescore}

if ! command -v cvlc &>/dev/null; then
    echo "Error: cvlc not found. Install VLC: sudo apt install vlc"
    exit 1
fi

echo "Starting VLC HTTP server on 127.0.0.1:${PORT} (password: ${PASS})"
echo "Stop with Ctrl-C"

exec cvlc \
    --extraintf http \
    --http-host 127.0.0.1 \
    --http-port "$PORT" \
    --http-password "$PASS" \
    --no-video \
    --quiet
