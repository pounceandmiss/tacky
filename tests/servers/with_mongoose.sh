#!/usr/bin/env bash
# with_mongoose.sh — spin up a MongooseIM XMPP server for integration testing.
# Usage: tests/servers/with_mongoose.sh <command> [args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# ─── Server config ───────────────────────────────────────────────────────────

DISPLAY_NAME="MongooseIM"
IMAGE="erlangsolutions/mongooseim:latest"
PG_IMAGE="postgres:16-alpine"
MAX_WAIT=90
INTERVAL=2
CONTAINER_NAME="mongooseim-test-$$"
PG_CONTAINER_NAME="mongooseim-pg-$$"
TEST_DIR="/tmp/mongooseim-test-$$"

PG_DB="mongooseim"
PG_USER="mongooseim"
PG_PASS="mongooseim"
PG_PORT=5432

export XMPP_SERVER="mongoose"

# ─── Callbacks ───────────────────────────────────────────────────────────────

_check_ready() {
  docker exec "${CONTAINER_NAME}" \
    /usr/lib/mongooseim/bin/mongooseimctl status 2>/dev/null | grep -q "started"
}

_register_user() {
  local container="$1" user="$2" domain="$3" pass="$4"
  docker exec "$container" \
    /usr/lib/mongooseim/bin/mongooseimctl \
    account registerUser \
    --username "$user" --domain "$domain" --password "$pass" >/dev/null 2>&1
}

# ─── Setup ───────────────────────────────────────────────────────────────────

lib_cleanup_stale "$TEST_DIR" "$CONTAINER_NAME"
docker rm -f "$PG_CONTAINER_NAME" >/dev/null 2>&1 || true
trap 'lib_cleanup "$CONTAINER_NAME" "$TEST_DIR" "$DISPLAY_NAME"; docker rm -f "$PG_CONTAINER_NAME" >/dev/null 2>&1 || true' EXIT INT TERM HUP

lib_generate_certs "$TEST_DIR"

# ─── MongooseIM config ───────────────────────────────────────────────────────

cat > "${TEST_DIR}/conf/mongooseim.toml" <<EOF
[general]
  loglevel = "warning"
  hosts = ["${DOMAIN}"]
  default_server_domain = "${DOMAIN}"
  registration_timeout = "infinity"
  language = "en"

[[listen.c2s]]
  port = 5222
  access = "c2s"
  shaper = "normal"
  max_stanza_size = 65536
  backwards_compatible_session = false
  tls.verify_mode = "none"
  tls.certfile = "/certs/${DOMAIN}.crt"
  tls.keyfile = "/certs/${DOMAIN}.key"

[[listen.s2s]]
  port = 5269
  shaper = "fast"
  max_stanza_size = 131072
  tls.verify_mode = "none"
  tls.certfile = "/certs/${DOMAIN}.crt"
  tls.keyfile = "/certs/${DOMAIN}.key"

[[listen.http]]
  port = 5280
  transport.num_acceptors = 10
  transport.max_connections = 1024

  [[listen.http.handlers.mongoose_bosh_handler]]
    host = "_"
    path = "/http-bind"

[[listen.http]]
  ip_address = "127.0.0.1"
  port = 5551
  transport.num_acceptors = 10
  transport.max_connections = 1024

  [[listen.http.handlers.mongoose_graphql_handler]]
    host = "localhost"
    path = "/api/graphql"
    schema_endpoint = "admin"
    username = "admin"
    password = "secret"

[auth]
  [auth.internal]

[internal_databases.mnesia]

[outgoing_pools.rdbms.default]
  scope = "global"
  workers = 5

  [outgoing_pools.rdbms.default.connection]
    driver = "pgsql"
    host = "127.0.0.1"
    port = ${PG_PORT}
    database = "${PG_DB}"
    username = "${PG_USER}"
    password = "${PG_PASS}"

[modules.mod_adhoc]
[modules.mod_disco]
  users_can_see_hidden_services = false
[modules.mod_stream_management]
[modules.mod_register]
  ip_access = [
    {address = "127.0.0.0/8", policy = "allow"},
    {address = "0.0.0.0/0", policy = "allow"}
  ]
  access = "register"
[modules.mod_caps]
[modules.mod_presence]
[modules.mod_vcard]
  host = "vjud.@HOST@"
[modules.mod_carboncopy]
[modules.mod_roster]
  versioning = true
  store_current_id = true
[modules.mod_pubsub]
  plugins = ["flat", "pep"]
  last_item_cache = "mnesia"

[[modules.mod_pubsub.pep_mapping]]
  namespace = "urn:xmpp:avatar:metadata"
  node = "flat"

[[modules.mod_pubsub.pep_mapping]]
  namespace = "urn:xmpp:avatar:data"
  node = "flat"
[modules.mod_private]
  backend = "mnesia"
[modules.mod_ping]
[modules.mod_mam]
  backend = "rdbms"
  full_text_search = true
  [modules.mod_mam.pm]

[shaper.normal]
  max_rate = 16_384
[shaper.fast]
  max_rate = 50_000

[acl]
  local = [{}]

[access]
  max_user_sessions = [{acl = "all", value = 10}]
  local = [{acl = "local", value = "allow"}]
  c2s = [{acl = "blocked", value = "deny"}, {acl = "all", value = "allow"}]
  register = [{acl = "all", value = "allow"}]

[s2s]
  default_policy = "deny"
EOF

# ─── Start PostgreSQL ────────────────────────────────────────────────────────

lib_pull_image "$PG_IMAGE"

docker run -d \
  --name "${PG_CONTAINER_NAME}" \
  --network host \
  -e POSTGRES_DB="${PG_DB}" \
  -e POSTGRES_USER="${PG_USER}" \
  -e POSTGRES_PASSWORD="${PG_PASS}" \
  "${PG_IMAGE}" >/dev/null

# Wait for PostgreSQL database to be ready
_pg_elapsed=0
until docker exec "${PG_CONTAINER_NAME}" psql -U "${PG_USER}" -d "${PG_DB}" -c "SELECT 1" >/dev/null 2>&1; do
  sleep 1
  _pg_elapsed=$((_pg_elapsed + 1))
  if [ "$_pg_elapsed" -ge 30 ]; then
    echo "ERROR: PostgreSQL did not start within 30s."
    exit 1
  fi
done

# Load MongooseIM schema
docker run --rm --entrypoint sh \
  "${IMAGE}" -c 'cat /usr/lib/mongooseim/lib/mongooseim-*/priv/pg.sql' \
  | docker exec -i "${PG_CONTAINER_NAME}" psql -U "${PG_USER}" -d "${PG_DB}" -q

# ─── Start MongooseIM ────────────────────────────────────────────────────────

lib_pull_image "$IMAGE"

docker run -d \
  --name "${CONTAINER_NAME}" \
  --network host \
  -v "${TEST_DIR}/conf/mongooseim.toml":/usr/lib/mongooseim/etc/mongooseim.toml:ro \
  -v "${TEST_DIR}/certs":/certs:ro \
  "${IMAGE}" >/dev/null

lib_wait_for_ready "$DISPLAY_NAME" "$MAX_WAIT" "$INTERVAL" _check_ready
lib_add_hosts_entry
lib_create_users "$CONTAINER_NAME" _register_user
lib_banner "$DISPLAY_NAME"
lib_run_command "$@"
