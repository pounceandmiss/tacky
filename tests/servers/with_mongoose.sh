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

lib_pick_ports XMPP_PORT HTTP_PORT GRAPHQL_PORT PG_PORT

export XMPP_SERVER="mongoose"
export XMPP_PORT
# mod_stream_management is in the config below: tests that need it check this.
export XMPP_SM=1

# ─── Callbacks ───────────────────────────────────────────────────────────────

_check_ready() {
  lib_output_has "started" \
    docker exec "${CONTAINER_NAME}" /usr/lib/mongooseim/bin/mongooseimctl status
}

_register_user() {
  local container="$1" user="$2" domain="$3" pass="$4"
  docker exec "$container" \
    /usr/lib/mongooseim/bin/mongooseimctl \
    account registerUser \
    --username "$user" --domain "$domain" --password "$pass" >/dev/null 2>&1
}

# ─── Setup ───────────────────────────────────────────────────────────────────

lib_cleanup "$TEST_DIR" "$CONTAINER_NAME" "$PG_CONTAINER_NAME"
trap 'lib_cleanup "$TEST_DIR" "$CONTAINER_NAME" "$PG_CONTAINER_NAME"' EXIT INT TERM HUP

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
  port = ${XMPP_PORT}
  access = "c2s"
  shaper = "normal"
  max_stanza_size = 65536
  backwards_compatible_session = false
  tls.verify_mode = "none"
  tls.certfile = "/certs/${DOMAIN}.crt"
  tls.keyfile = "/certs/${DOMAIN}.key"

[[listen.http]]
  port = ${HTTP_PORT}
  transport.num_acceptors = 10
  transport.max_connections = 1024

  [[listen.http.handlers.mongoose_bosh_handler]]
    host = "_"
    path = "/http-bind"

[[listen.http]]
  ip_address = "127.0.0.1"
  port = ${GRAPHQL_PORT}
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
# mod_caps needs cets since 6.6; cets uses the rdbms pool below.
[internal_databases.cets]

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
[modules.mod_blocking]
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
  # Archive each message as it is routed: the default writer batches them
  # into the database every few seconds, and a test querying the archive
  # just after a send would find it empty.
  [modules.mod_mam.async_writer]
    enabled = false
  [modules.mod_mam.pm]
  [modules.mod_mam.muc]
    host = "conference.@HOST@"
# Rooms at conference.<domain>, as on the other test servers.
[modules.mod_muc]
  host = "conference.@HOST@"
  access = "muc"
  access_create = "muc_create"

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
  muc = [{acl = "all", value = "allow"}]
  muc_create = [{acl = "local", value = "allow"}]

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
  "${PG_IMAGE}" -c port="${PG_PORT}" >/dev/null

_pg_ready() {
  docker exec "${PG_CONTAINER_NAME}" \
    psql -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" -c "SELECT 1" >/dev/null 2>&1
}
lib_wait_for_ready PostgreSQL 30 1 _pg_ready

# Load MongooseIM schema
docker run --rm --entrypoint sh \
  "${IMAGE}" -c 'cat /usr/lib/mongooseim/lib/mongooseim-*/priv/pg.sql' \
  | docker exec -i "${PG_CONTAINER_NAME}" psql -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" -q

# ─── Start MongooseIM ────────────────────────────────────────────────────────

lib_pull_image "$IMAGE"

docker run -d \
  --name "${CONTAINER_NAME}" \
  --network host \
  -v "${TEST_DIR}/conf/mongooseim.toml":/usr/lib/mongooseim/etc/mongooseim.toml:ro \
  -v "${TEST_DIR}/certs":/certs:ro \
  "${IMAGE}" >/dev/null

lib_wait_for_ready "$DISPLAY_NAME" "$MAX_WAIT" "$INTERVAL" _check_ready
lib_finish "$DISPLAY_NAME" "$CONTAINER_NAME" _register_user "$@"
