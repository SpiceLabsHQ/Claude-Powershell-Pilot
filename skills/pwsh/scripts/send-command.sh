#!/bin/bash
# Usage: echo '<pwsh command>' | bash send-command.sh <session> [timeout]
# Reads the PowerShell command from stdin (multi-line supported), sends it to
# the session, and prints the sentinel line when the command completes.
# Stale sentinels from earlier timed-out commands are discarded, not returned.

SESSION="${1:-default}"
TIMEOUT="${2:-120}"

CMD="$(cat)"
CMD_ID="$$-$(date +%s)-$RANDOM"
PAYLOAD="RUN:${CMD_ID}:$(printf '%s' "$CMD" | base64 | tr -d '\n')"
printf '%s\n' "$PAYLOAD" > "/tmp/pwsh_sess_${SESSION}_cmd"

DEADLINE=$((SECONDS + TIMEOUT))
while :; do
  REMAINING=$((DEADLINE - SECONDS))
  if [ "$REMAINING" -le 0 ]; then
    echo "ERROR: timed out waiting for response after ${TIMEOUT}s" >&2
    exit 1
  fi
  if ! IFS= read -r -t "$REMAINING" line < "/tmp/pwsh_sess_${SESSION}_result"; then
    continue
  fi
  case "$line" in
    "DONE:${CMD_ID}:"*) echo "$line"; exit 0 ;;
    *) ;;  # stale sentinel, late READY, or stray output — discard
  esac
done
