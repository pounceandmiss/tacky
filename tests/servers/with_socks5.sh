#!/usr/bin/env bash
# with_socks5.sh — run a command jailed behind a SOCKS5 proxy.
# Usage: tests/servers/with_prosody.sh tests/servers/with_socks5.sh <command> [args...]
#
# Starts Dante (socks5/) on the host and runs <command> in a network
# namespace of its own, where the only reachable address is the proxy's: any
# connection that goes around the proxy - the server, its HTTP upload, a DNS
# query - is refused. The proxy resolves example.local itself.
#
# Exported to <command>: SOCKS5_PROXY (socks5://user:pass@127.0.0.1:port) and
# SOCKS5_CONTAINER, whose log (docker logs) has a line per CONNECT.
#
# The jail is unshare -rn (an empty network namespace) with a single door: a
# unix socket, which socat carries to the proxy's port on either side.
# Needs socat, and unprivileged user namespaces.
set -euo pipefail

for tool in socat unshare; do
  command -v "$tool" >/dev/null || { echo "with_socks5.sh: needs $tool" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

IMAGE="tacky-socks5:test"
CONTAINER_NAME="socks5-test-$$"
TEST_DIR="/tmp/socks5-test-$$"

lib_pick_ports SOCKS5_PORT

cleanup() {
  [ -n "${BRIDGE_PID:-}" ] && kill "$BRIDGE_PID" 2>/dev/null || true
  lib_cleanup "$TEST_DIR" "$CONTAINER_NAME"
}
trap cleanup EXIT
cleanup
mkdir -p "$TEST_DIR"

echo ">>> Building $IMAGE (cached layers reused on re-run)"
docker build --quiet --network host -t "$IMAGE" "$SCRIPT_DIR/socks5" >/dev/null
sed "s/@PORT@/${SOCKS5_PORT}/" "$SCRIPT_DIR/socks5/sockd.conf" > "$TEST_DIR/sockd.conf"
docker run -d --name "$CONTAINER_NAME" --network host \
  --add-host "${DOMAIN}:127.0.0.1" \
  -v "$TEST_DIR/sockd.conf":/etc/sockd.conf:ro \
  "$IMAGE" >/dev/null

_check_ready() { (exec 3<>"/dev/tcp/127.0.0.1/${SOCKS5_PORT}") 2>/dev/null; }
lib_wait_for_ready "Dante" 20 1 _check_ready

DOOR="$TEST_DIR/door"
socat "UNIX-LISTEN:${DOOR},fork" "TCP:127.0.0.1:${SOCKS5_PORT}" &
BRIDGE_PID=$!
until [ -S "$DOOR" ]; do sleep 0.1; done

export SOCKS5_PROXY="socks5://proxyuser:proxypass@127.0.0.1:${SOCKS5_PORT}"
export SOCKS5_CONTAINER="$CONTAINER_NAME"
echo ">>> SOCKS5 proxy ready ($SOCKS5_PROXY); the command runs jailed behind it"

if [ "$#" -eq 0 ]; then exit 0; fi
set +e
# Inside: the proxy's address, carried out through the door. The command
# starts once socat listens, and socat goes with the namespace when it ends.
unshare -rn sh -c '
  ip link set lo up || exit 1
  socat "TCP-LISTEN:$1,bind=127.0.0.1,reuseaddr,fork" "UNIX-CONNECT:$2" &
  door=$!
  until ss -Hltn "sport = :$1" | grep -q .; do sleep 0.1; done
  shift 2
  "$@"
  code=$?
  kill $door 2>/dev/null
  exit $code
' jail "$SOCKS5_PORT" "$DOOR" "$@"
code=$?
set -e
exit $code
