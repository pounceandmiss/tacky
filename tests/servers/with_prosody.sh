#!/usr/bin/env bash
# with_prosody.sh — spin up a Prosody XMPP server for integration testing.
# Usage: tests/servers/with_prosody.sh [--sm] <command> [args...]
#
# Flags:
#   --sm   Enable XEP-0198 Stream Management (smacks module)
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
ENABLE_SM=false

export XMPP_SERVER="prosody"

# ─── Parse arguments ─────────────────────────────────────────────────────────

args=()
for arg in "$@"; do
  case "$arg" in
    --sm)
      ENABLE_SM=true
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
    && (exec 3<>"/dev/tcp/127.0.0.1/${PORT_HOST}") 2>/dev/null \
    && exec 3<&- 3>&-
}

_register_user() {
  local container="$1" user="$2" domain="$3" pass="$4"
  docker exec "$container" prosodyctl register "$user" "$domain" "$pass" >/dev/null 2>&1
}

# ─── Setup ───────────────────────────────────────────────────────────────────

lib_cleanup_stale "$TEST_DIR" "$CONTAINER_NAME"
trap 'lib_cleanup "$CONTAINER_NAME" "$TEST_DIR" "$DISPLAY_NAME"' EXIT INT TERM HUP

lib_generate_certs "$TEST_DIR"

# ─── Prosody config ──────────────────────────────────────────────────────────

SM_MODULE=""
if [ "$ENABLE_SM" = true ]; then
  SM_MODULE='"smacks";'
fi

cat > "${TEST_DIR}/conf/prosody.cfg.lua" <<EOF
admins = { }
modules_enabled = {
  "roster"; "saslauth"; "tls"; "dialback"; "disco"; "private";
  "vcard"; "version"; "uptime"; "time"; "ping"; "posix"; "pep";
  "register"; "mam";
  ${SM_MODULE}
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

lib_ensure_port_free "$CONTAINER_NAME"
lib_pull_image "$IMAGE"

docker run -d \
  --name "${CONTAINER_NAME}" \
  --network host \
  -v "${TEST_DIR}/conf/prosody.cfg.lua":/etc/prosody/prosody.cfg.lua:ro \
  -v "${TEST_DIR}/certs":/etc/prosody/certs:ro \
  "${IMAGE}" >/dev/null

lib_wait_for_ready "$DISPLAY_NAME" "$MAX_WAIT" "$INTERVAL" _check_ready
lib_add_hosts_entry
lib_create_users "$CONTAINER_NAME" _register_user
lib_banner "$DISPLAY_NAME"
lib_run_command "$@"
