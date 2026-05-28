#!/usr/bin/env bash
# run-smoke.sh — invoke smoke.py inside the bot container's venv.
# Designed to be the <command> passed to with_prosody.sh + with_bot.sh:
#
#   tests/servers/with_prosody.sh \
#     tests/servers/omemo-bot/with_bot.sh \
#       tests/servers/omemo-bot/run-smoke.sh

set -euo pipefail

if [ -z "${OMEMO_BOT_CONTAINER:-}" ] || [ -z "${OMEMO_BOT_JID:-}" ]; then
  echo "ERROR: OMEMO_BOT_* env not set — run via with_bot.sh" >&2
  exit 2
fi

DOMAIN="example.local"
XMPP_PORT="${PORT_HOST:-5222}"

exec docker exec \
  -e TESTER_JID="test@${DOMAIN}" \
  -e TESTER_PASSWORD=testpass \
  -e BOT_JID="$OMEMO_BOT_JID" \
  -e XMPP_HOST="$DOMAIN" \
  -e XMPP_PORT="$XMPP_PORT" \
  -e CA_PATH=/opt/ca.crt \
  "$OMEMO_BOT_CONTAINER" /opt/bot-venv/bin/python /opt/smoke.py
