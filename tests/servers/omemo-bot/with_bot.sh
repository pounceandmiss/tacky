#!/usr/bin/env bash
# with_bot.sh — start an OMEMO echo-bot sidecar alongside a running prosody
# (started by tests/servers/with_prosody.sh) and run <command> with the bot
# present. Trap-driven teardown.
#
# Usage:
#   tests/servers/with_prosody.sh tests/servers/omemo-bot/with_bot.sh <command> [args...]
#
# Inside <command> the following are exported:
#   OMEMO_BOT_JID         bot@example.local
#   OMEMO_BOT_PASSWORD    botpass
#   OMEMO_BOT_CONTAINER   docker container name (e.g. for docker exec)
# Plus everything with_prosody.sh exports: SPOOF_SSL_CERT, XMPP_SERVER.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="tacky-omemo-bot:test"
BOT_READY_TIMEOUT=20

DOMAIN="example.local"
BOT_USER="bot"
BOT_PASSWORD="botpass"
XMPP_PORT="${PORT_HOST:-5222}"

export OMEMO_BOT_JID="${BOT_USER}@${DOMAIN}"
export OMEMO_BOT_PASSWORD="$BOT_PASSWORD"
export OMEMO_BOT_CONTAINER="omemo-bot-test-$$"

if [ -z "${SPOOF_SSL_CERT:-}" ]; then
  echo "ERROR: SPOOF_SSL_CERT not set — run this via tests/servers/with_prosody.sh" >&2
  exit 2
fi

cleanup() {
  if [ -n "${DUMP_BOT_LOGS:-}" ]; then
    echo "===== BOT LOGS =====" >&2
    docker logs "$OMEMO_BOT_CONTAINER" >&2 2>&1 || true
    echo "===== /BOT LOGS =====" >&2
  fi
  docker rm -f "$OMEMO_BOT_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

echo ">>> Locating prosody container"
PROSODY_CONTAINER="$(docker ps --filter 'name=prosody-test-' --format '{{.Names}}' | head -n1)"
if [ -z "$PROSODY_CONTAINER" ]; then
  echo "ERROR: no prosody-test-* container running" >&2
  exit 2
fi
echo "    found: $PROSODY_CONTAINER"

echo ">>> Building $IMAGE (cached layers reused on re-run)"
docker build --network host -t "$IMAGE" "$SCRIPT_DIR"

echo ">>> Registering ${OMEMO_BOT_JID}"
docker exec "$PROSODY_CONTAINER" \
  prosodyctl register "$BOT_USER" "$DOMAIN" "$BOT_PASSWORD" >/dev/null 2>&1 || true

echo ">>> Starting bot sidecar ($OMEMO_BOT_CONTAINER)"
docker run -d --name "$OMEMO_BOT_CONTAINER" \
  --network host \
  -e BOT_JID="$OMEMO_BOT_JID" \
  -e BOT_PASSWORD="$BOT_PASSWORD" \
  -e XMPP_HOST="$DOMAIN" \
  -e XMPP_PORT="$XMPP_PORT" \
  -e CA_PATH=/opt/ca.crt \
  -v "${SPOOF_SSL_CERT}:/opt/ca.crt:ro" \
  "$IMAGE" >/dev/null

echo ">>> Waiting for 'OMEMO bot online' (max ${BOT_READY_TIMEOUT}s)"
elapsed=0
until docker logs "$OMEMO_BOT_CONTAINER" 2>&1 | grep -q 'OMEMO bot online'; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge "$BOT_READY_TIMEOUT" ]; then
    echo "ERROR: bot did not come online within ${BOT_READY_TIMEOUT}s" >&2
    echo "--- bot logs ---" >&2
    docker logs "$OMEMO_BOT_CONTAINER" >&2 || true
    exit 1
  fi
done
echo "    bot online"

if [ "$#" -eq 0 ]; then
  echo ">>> No command provided. Bot container will be torn down now."
  exit 0
fi

set +e
"$@"
rc=$?
set -e

if [ $rc -ne 0 ]; then
  echo "--- bot logs (on failure) ---" >&2
  docker logs "$OMEMO_BOT_CONTAINER" >&2 || true
fi

exit $rc
