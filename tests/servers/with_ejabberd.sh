#!/usr/bin/env bash
# with_ejabberd.sh — spin up an ejabberd XMPP server for integration testing.
# Usage: tests/servers/with_ejabberd.sh <command> [args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# ─── Server config ───────────────────────────────────────────────────────────

DISPLAY_NAME="ejabberd"
IMAGE="ghcr.io/processone/ejabberd:latest"
MYSQL_IMAGE="mysql:8.0"
MAX_WAIT=50
INTERVAL=2
CONTAINER_NAME="ejabberd-test-$$"
MYSQL_CONTAINER_NAME="ejabberd-mysql-$$"
TEST_DIR="/tmp/ejabberd-test-$$"

MYSQL_DB="ejabberd"
MYSQL_USER="ejabberd"
MYSQL_PASS="ejabberd"
MYSQL_ROOT_PASS="root"
MYSQL_PORT=3306

export XMPP_SERVER="ejabberd"

# ─── Callbacks ───────────────────────────────────────────────────────────────

_check_ready() {
  docker exec "${CONTAINER_NAME}" \
    ejabberdctl status 2>/dev/null | grep -q "started"
}

_register_user() {
  local container="$1" user="$2" domain="$3" pass="$4"
  docker exec "$container" \
    ejabberdctl register "$user" "$domain" "$pass" >/dev/null 2>/dev/null
}

# ─── Setup ───────────────────────────────────────────────────────────────────

lib_cleanup_stale "$TEST_DIR" "$CONTAINER_NAME"
docker rm -f "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || true
trap 'lib_cleanup "$CONTAINER_NAME" "$TEST_DIR" "$DISPLAY_NAME"; docker rm -f "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || true' EXIT INT TERM HUP

lib_generate_certs "$TEST_DIR"

# ejabberd expects a single PEM file with cert + key combined
cat "${TEST_DIR}/certs/${DOMAIN}.crt" "${TEST_DIR}/certs/${DOMAIN}.key" \
  > "${TEST_DIR}/certs/${DOMAIN}.pem"
chmod 644 "${TEST_DIR}/certs/${DOMAIN}.pem"

# ─── ejabberd config ─────────────────────────────────────────────────────────

cat > "${TEST_DIR}/conf/ejabberd.yml" <<EOF
loglevel: warning

hosts:
  - "${DOMAIN}"

certfiles:
  - /opt/ejabberd/certs/${DOMAIN}.pem

sql_type: mysql
sql_server: "127.0.0.1"
sql_port: ${MYSQL_PORT}
sql_database: "${MYSQL_DB}"
sql_username: "${MYSQL_USER}"
sql_password: "${MYSQL_PASS}"

listen:
  -
    port: 5222
    ip: "::"
    module: ejabberd_c2s
    max_stanza_size: 262144
    shaper: c2s_shaper
    access: c2s
    starttls: true
    starttls_required: false
  -
    port: 5269
    ip: "::"
    module: ejabberd_s2s_in
    max_stanza_size: 524288
  -
    port: 5280
    ip: "::"
    module: ejabberd_http
    request_handlers:
      /admin: ejabberd_web_admin
      /api: mod_http_api
      /bosh: mod_bosh

s2s_use_starttls: optional

acl:
  local:
    user_regexp: ""
  loopback:
    ip:
      - 127.0.0.0/8
      - ::1/128
  admin:
    user:
      - admin@${DOMAIN}

access_rules:
  local:
    allow: local
  c2s:
    deny: blocked
    allow: all
  register:
    allow: all

shaper:
  normal:
    rate: 16384
    burst_size: 65536
  fast:
    rate: 50000
    burst_size: 200000

shaper_rules:
  max_user_sessions: 10
  c2s_shaper:
    none: admin
    normal: all
  s2s_shaper: fast

modules:
  mod_adhoc: {}
  mod_admin_extra: {}
  mod_bosh: {}
  mod_caps: {}
  mod_carboncopy: {}
  mod_disco: {}
  mod_http_api: {}
  mod_mam:
    db_type: sql
    default: always
  mod_ping: {}
  mod_private: {}
  mod_pubsub:
    plugins:
      - flat
      - pep
    force_node_config:
      "urn:xmpp:avatar:data":
        persist_items: true
        max_items: 1
        access_model: open
      "urn:xmpp:avatar:metadata":
        persist_items: true
        max_items: 1
        access_model: open
  mod_register:
    ip_access: all
  mod_roster:
    versioning: true
    store_current_id: true
  mod_stream_mgmt: {}
  mod_vcard: {}

api_permissions:
  "console commands":
    from:
      - ejabberd_ctl
    who: all
    what: "*"
  "admin access":
    who:
      access:
        allow:
          - loopback
    what:
      - "*"
      - "!stop"
      - "!start"
EOF

# ─── Start MySQL ─────────────────────────────────────────────────────────────

lib_pull_image "$MYSQL_IMAGE"

docker run -d \
  --name "${MYSQL_CONTAINER_NAME}" \
  --network host \
  -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASS}" \
  -e MYSQL_DATABASE="${MYSQL_DB}" \
  -e MYSQL_USER="${MYSQL_USER}" \
  -e MYSQL_PASSWORD="${MYSQL_PASS}" \
  "${MYSQL_IMAGE}" \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci >/dev/null

# Wait for MySQL to accept connections with the application user
_mysql_elapsed=0
until docker exec "${MYSQL_CONTAINER_NAME}" \
  mysql -u "${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}" -e "SELECT 1" >/dev/null 2>&1; do
  sleep 2
  _mysql_elapsed=$((_mysql_elapsed + 2))
  if [ "$_mysql_elapsed" -ge 60 ]; then
    echo "ERROR: MySQL did not start within 60s."
    exit 1
  fi
done

# Load ejabberd SQL schema
docker run --rm --network none --entrypoint cat \
  "${IMAGE}" /opt/ejabberd/sql/mysql.sql \
  | docker exec -i "${MYSQL_CONTAINER_NAME}" \
    mysql -u "${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}"

# ─── Start ejabberd ──────────────────────────────────────────────────────────

lib_pull_image "$IMAGE"

docker run -d \
  --name "${CONTAINER_NAME}" \
  --network host \
  -v "${TEST_DIR}/conf/ejabberd.yml":/opt/ejabberd/conf/ejabberd.yml:ro \
  -v "${TEST_DIR}/certs":/opt/ejabberd/certs:ro \
  "${IMAGE}" >/dev/null

lib_wait_for_ready "$DISPLAY_NAME" "$MAX_WAIT" "$INTERVAL" _check_ready
lib_add_hosts_entry
lib_create_users "$CONTAINER_NAME" _register_user
lib_banner "$DISPLAY_NAME"
lib_run_command "$@"
