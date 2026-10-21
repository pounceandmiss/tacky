#!/usr/bin/env bash
# with_netns.sh - run a command in a network of its own, to break media paths
# for real. Rootless: a user and network namespace (unshare -rn), in which the
# command is root and may change the network as it likes.
#
# Usage, under a server harness:
#   tests/servers/with_prosody.sh tests/servers/with_netns.sh <command> [args...]
#
# Inside:
#   lo   up, so the XMPP server stays at 127.0.0.1:$XMPP_PORT (example.local):
#        a socat pair bridges that port to the server outside through a unix
#        socket, the filesystem being shared between the namespaces
#   d0   a dummy interface, up, 10.9.0.1/24: the only address ICE gathers on
#   d1   a dummy interface, up, no address: a network to switch to
#   no IPv6, so the one IPv4 address is the only path there is
#
# A test breaks the path with nft (`nft add table inet cut ...` dropping UDP
# to 10.9.0.1) and gives the "new network" with `ip addr add 10.9.1.1/24 dev
# d1`. Exported: NETNS=1, NETNS_PATH_A=10.9.0.1, NETNS_PATH_B=10.9.1.1.
set -euo pipefail

if [[ -z "${XMPP_PORT:-}" ]]; then
  echo "with_netns.sh: no XMPP_PORT; run it under a server harness" >&2
  exit 2
fi
for tool in unshare ip nft socat; do
  command -v "$tool" >/dev/null || { echo "with_netns.sh: needs $tool" >&2; exit 2; }
done

SOCK_DIR="$(mktemp -d)"
SOCK="$SOCK_DIR/xmpp.sock"
socat "UNIX-LISTEN:$SOCK,fork" "TCP:127.0.0.1:$XMPP_PORT" &
OUTSIDE=$!
trap 'kill $OUTSIDE 2>/dev/null; rm -rf "$SOCK_DIR"' EXIT
for _ in $(seq 50); do [[ -S "$SOCK" ]] && break; sleep 0.1; done

export NETNS=1 NETNS_PATH_A=10.9.0.1 NETNS_PATH_B=10.9.1.1 NETNS_SOCK="$SOCK"
unshare -rn bash -c '
  set -e
  # IPv4 only: the dummies would get IPv6 link-local addresses, a second
  # path the cut below leaves open (libwebrtc uses them).
  echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
  echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6
  ip link set lo up
  ip link add d0 type dummy
  ip link add d1 type dummy
  ip addr add "$NETNS_PATH_A/24" dev d0
  ip link set d0 up
  ip link set d1 up
  socat "TCP-LISTEN:$XMPP_PORT,bind=127.0.0.1,fork,reuseaddr" "UNIX-CONNECT:$NETNS_SOCK" &
  for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$XMPP_PORT") 2>/dev/null && break; sleep 0.1; done
  "$@"
' with_netns "$@"
