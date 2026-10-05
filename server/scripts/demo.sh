#!/bin/zsh
# Starts a throwaway Frndstr server full of demo data (users, posts, moments; gradient photos).
#   scripts/demo.sh            reuse the demo data from last time (or create it)
#   scripts/demo.sh --reset    start over with fresh demo data
# Env: DEMO_DIR (default /tmp/frndstr-demo), PORT (default 8090).
set -euo pipefail

cd "${0:A:h}/.."
DEMO_DIR="${DEMO_DIR:-/tmp/frndstr-demo}"
PORT="${PORT:-8090}"
SCRATCH=/tmp/frndstr-build/server
# The Command Line Tools alone can't build the tests' macros; prefer full Xcode when it's there.
[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

[[ "${1:-}" == "--reset" ]] && rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"
export DATA_DIR="$DEMO_DIR" INSTANCE_NAME="Frndstr Demo"

swift build --scratch-path "$SCRATCH" -q
BIN="$SCRATCH/debug/App"

if [[ ! -f "$DEMO_DIR/.seeded" ]]; then
    "$BIN" seed
    touch "$DEMO_DIR/.seeded"
fi

IP=$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)
echo
echo "Demo server: http://$IP:$PORT  (simulator: localhost:$PORT)"
echo "Sign in: demo / demodemo   ·   data in $DEMO_DIR   ·   Ctrl-C to stop"
echo
exec "$BIN" serve --hostname 0.0.0.0 --port "$PORT"
