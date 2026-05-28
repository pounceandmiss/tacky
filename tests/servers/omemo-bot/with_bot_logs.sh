#!/usr/bin/env bash
# Variant of with_bot.sh that also dumps the bot container logs to
# stderr after the command finishes, so we can see what the bot
# thought of our messages.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/with_bot.sh" "$@"
rc=$?
echo "===== BOT LOGS =====" >&2
docker logs "$OMEMO_BOT_CONTAINER" 2>&1 | tail -60 >&2
echo "===== /BOT LOGS =====" >&2
exit $rc
