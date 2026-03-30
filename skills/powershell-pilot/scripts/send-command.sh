#!/bin/bash
# Usage: echo '<pwsh command>' | bash send-command.sh <session> [timeout]
# Reads the PowerShell command from stdin, sends it to the session,
# and prints the sentinel line when the command completes.

SESSION="${1:-default}"
TIMEOUT="${2:-120}"

CMD="$(cat)"
printf '%s\n' "$CMD" > "/tmp/pwsh_sess_${SESSION}_cmd"

IFS= read -r -t "$TIMEOUT" sentinel < "/tmp/pwsh_sess_${SESSION}_result"
if [ $? -ne 0 ]; then
  echo "ERROR: timed out waiting for response after ${TIMEOUT}s" >&2
  exit 1
fi

echo "$sentinel"
