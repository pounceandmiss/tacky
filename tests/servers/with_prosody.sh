#!/usr/bin/env bash
# with_prosody.sh — spin up a Prosody XMPP server for integration testing.
# Usage: tests/servers/with_prosody.sh [--no-sm] <command> [args...]
#
# Flags:
#   --no-sm   Leave out XEP-0198 Stream Management (smacks), which is on by
#             default as on the servers people use
#   --sm      Accepted for old command lines; it is the default
#
# Exported to <command>: XMPP_SERVER, XMPP_PORT, XMPP_WS_URL, SPOOF_SSL_CERT,
# PROSODY_CONTAINER.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# ─── Server config ───────────────────────────────────────────────────────────

DISPLAY_NAME="Prosody"
IMAGE="prosodyim/prosody:13.0"
MAX_WAIT=20
INTERVAL=1
CONTAINER_NAME="prosody-test-$$"
TEST_DIR="/tmp/prosody-test-$$"
ENABLE_SM=true

lib_pick_ports XMPP_PORT HTTP_PORT

export XMPP_SERVER="prosody"
export XMPP_PORT
export XMPP_WS_URL="ws://127.0.0.1:${HTTP_PORT}/xmpp-websocket"
export PROSODY_CONTAINER="$CONTAINER_NAME"

# ─── Parse arguments ─────────────────────────────────────────────────────────

args=()
for arg in "$@"; do
  case "$arg" in
    --sm)
      ENABLE_SM=true
      ;;
    --no-sm)
      ENABLE_SM=false
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

# ─── Callbacks ───────────────────────────────────────────────────────────────

_check_ready() {
  docker exec "${CONTAINER_NAME}" prosodyctl about >/dev/null 2>&1 \
    && (exec 3<>"/dev/tcp/127.0.0.1/${XMPP_PORT}") 2>/dev/null \
    && exec 3<&- 3>&-
}

_register_user() {
  local container="$1" user="$2" domain="$3" pass="$4"
  docker exec "$container" prosodyctl register "$user" "$domain" "$pass" >/dev/null 2>&1
}

# ─── Setup ───────────────────────────────────────────────────────────────────

lib_cleanup "$TEST_DIR" "$CONTAINER_NAME"
trap 'lib_cleanup "$TEST_DIR" "$CONTAINER_NAME"' EXIT INT TERM HUP

lib_generate_certs "$TEST_DIR"

# ─── Prosody config ──────────────────────────────────────────────────────────

SM_MODULE=""
if [ "$ENABLE_SM" = true ]; then
  SM_MODULE='"smacks";'
  # Tests that need stream management check for it.
  export XMPP_SM=1
fi

cat > "${TEST_DIR}/conf/prosody.cfg.lua" <<EOF
admins = { }
modules_enabled = {
  "roster"; "saslauth"; "tls"; "dialback"; "disco"; "private";
  "vcard"; "version"; "uptime"; "time"; "ping"; "posix"; "pep";
  "register"; "mam"; "blocklist";
  "http"; "websocket"; "http_file_share";
  ${SM_MODULE}
}

-- Only the two listeners the tests use, on this run's ports; the fixed
-- defaults (5269, 5281, ...) would collide with a concurrent run.
c2s_ports = { ${XMPP_PORT} }
http_ports = { ${HTTP_PORT} }
https_ports = { }
s2s_ports = { }
c2s_direct_tls_ports = { }
s2s_direct_tls_ports = { }
component_ports = { }

-- XMPP over WebSocket (RFC 7395), at ${XMPP_WS_URL}, for
-- the wasm build: a browser page has no sockets, so this is the only way in.
-- Two settings make that endpoint usable from a test rather than from a
-- deployment behind a TLS-terminating proxy:
--   the connection is plain ws://, and Prosody will not do SASL PLAIN on a
--   stream it considers unencrypted;
--   the page under test is served from a static server on another port, so
--   mod_websocket sees a cross-origin Origin header and checks it.
consider_websocket_secure = true

-- XEP-0363 file upload, on the VirtualHost rather than on a component of its
-- own: a component's HTTP lives under the component's own hostname, which
-- would be a second name to resolve. The slots it hands out are addressed by
-- the host's name rather than by 127.0.0.1, because Prosody routes HTTP by
-- the Host header and only ${DOMAIN} has /file_share on it - the harness
-- puts ${DOMAIN} in /etc/hosts for exactly this kind of reason.
http_file_share_size_limit = 10485760
http_external_url = "http://${DOMAIN}:${HTTP_PORT}/"

-- A page under test is served from a static server on a port of its own, so
-- every one of these endpoints is cross-origin to it.
http_cors_override = {
  websocket = { enabled = true };
  -- An override replaces the module's own settings, so the headers an upload
  -- slot carries have to be named again.
  file_share = { enabled = true; credentials = true; headers = { Authorization = true } };
}
allow_registration = true
daemonize = false
pidfile = "/var/run/prosody/prosody.pid"
storage = "internal"
tls = {
  key = "/etc/prosody/certs/${DOMAIN}.key";
  certificate = "/etc/prosody/certs/${DOMAIN}.crt";
}
pep_assume_unfiltered = true

log = {
  { levels = { min = "debug" }, to = "console" };
}

VirtualHost "${DOMAIN}"
    authentication = "internal_hashed"
    ssl = {
      key = "/etc/prosody/certs/${DOMAIN}.key";
      certificate = "/etc/prosody/certs/${DOMAIN}.crt";
    }

Component "conference.${DOMAIN}" "muc"
    restrict_room_creation = false
    muc_room_default_public = true
EOF

# ─── Start & wait ────────────────────────────────────────────────────────────

lib_pull_image "$IMAGE"

docker run -d \
  --name "${CONTAINER_NAME}" \
  --network host \
  -v "${TEST_DIR}/conf/prosody.cfg.lua":/etc/prosody/prosody.cfg.lua:ro \
  -v "${TEST_DIR}/certs":/etc/prosody/certs:ro \
  "${IMAGE}" >/dev/null

lib_wait_for_ready "$DISPLAY_NAME" "$MAX_WAIT" "$INTERVAL" _check_ready
lib_finish "$DISPLAY_NAME" "$CONTAINER_NAME" _register_user "$@"
