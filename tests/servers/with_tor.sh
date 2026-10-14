#!/usr/bin/env bash
# with_tor.sh — run a command next to a Tor of its own.
# Usage: tests/servers/with_tor.sh <command> [args...]
#
# Starts the host's tor, kept off the Tor network: its one bridge is a port
# where nothing listens, so it never bootstraps. Its SOCKS port still takes
# every request and says what it saw on the control port, which is what the
# suite checks - which login each connection came with (Tor's isolation),
# and the answers Tor gives itself, such as an invalid onion address. No
# connection gets anywhere, so this needs no server and no network.
#
# Exported to <command>: TOR_SOCKS (socks5://127.0.0.1:port, ExtendedErrors
# on), TOR_CONTROL_PORT and TOR_COOKIE (the control port's auth cookie).
# Needs tor.
set -euo pipefail

command -v tor >/dev/null || { echo "with_tor.sh: needs tor" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

TEST_DIR="/tmp/tor-test-$$"

lib_pick_ports TOR_SOCKS_PORT TOR_CONTROL_PORT

cleanup() {
  if [ -f "$TEST_DIR/pid" ]; then
    kill "$(cat "$TEST_DIR/pid")" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT
mkdir -p "$TEST_DIR/data"
chmod 700 "$TEST_DIR/data"

cat > "$TEST_DIR/torrc" <<EOF
DataDirectory $TEST_DIR/data
SocksPort 127.0.0.1:${TOR_SOCKS_PORT} ExtendedErrors
ControlPort 127.0.0.1:${TOR_CONTROL_PORT}
CookieAuthentication 1
UseBridges 1
Bridge 127.0.0.1:9
Log notice file $TEST_DIR/log
EOF
tor -f "$TEST_DIR/torrc" --RunAsDaemon 1 --PidFile "$TEST_DIR/pid" >/dev/null

_check_ready() {
  [ -f "$TEST_DIR/data/control_auth_cookie" ] \
    && (exec 3<>"/dev/tcp/127.0.0.1/${TOR_SOCKS_PORT}") 2>/dev/null \
    && (exec 3<>"/dev/tcp/127.0.0.1/${TOR_CONTROL_PORT}") 2>/dev/null
}
lib_wait_for_ready "Tor" 20 1 _check_ready

export TOR_SOCKS="socks5://127.0.0.1:${TOR_SOCKS_PORT}"
export TOR_CONTROL_PORT
export TOR_COOKIE="$TEST_DIR/data/control_auth_cookie"
echo ">>> Tor ready ($TOR_SOCKS, control port $TOR_CONTROL_PORT), off the network"

if [ "$#" -eq 0 ]; then exit 0; fi
set +e
"$@"
code=$?
set -e
exit $code
