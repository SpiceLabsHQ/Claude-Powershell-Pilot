#!/bin/bash
# Usage: bash run-command.sh <session> [timeout] [grep_pattern] <<'EOF'
#        <pwsh command — single line or a full multi-line script>
#        EOF
# Sends a command to the named session and reads the output in one call.
# The whole of stdin is sent as one unit, so multi-line scripts (try/catch,
# loops, here-strings) work exactly like they would in an interactive shell.
#
# Wire protocol: the command travels base64-encoded on a single line as
#   RUN:<id>:<base64>
# and the runner answers with
#   DONE:<id>:<exitCode>:<stdoutFile>:<stderrFile>:<lineCount>
# The id lets this script wait for its own sentinel and discard stale ones
# left behind by earlier timed-out commands, so output can never come back
# one command behind.

SESSION="${1:-default}"
TIMEOUT="${2:-120}"
PATTERN="${3:-}"

PID_FILE="/tmp/pwsh_sess_${SESSION}.pid"
if [ ! -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "ERROR: session runner is not running. Start it with run-session.sh." >&2
  exit 2
fi

CMD="$(cat)"
CMD_ID="$$-$(date +%s)-$RANDOM"
PAYLOAD="RUN:${CMD_ID}:$(printf '%s' "$CMD" | base64 | tr -d '\n')"

# Write to the cmd FIFO with a 10s timeout.
# A plain redirect blocks forever if the runner is not reading (e.g. it died
# between the liveness check above and here). The killer subshell prevents that.
(printf '%s\n' "$PAYLOAD" > "/tmp/pwsh_sess_${SESSION}_cmd") &
WRITER=$!
( sleep 10; kill "$WRITER" 2>/dev/null ) &
WRITE_KILLER=$!
wait "$WRITER"
WRITE_STATUS=$?
kill "$WRITE_KILLER" 2>/dev/null; wait "$WRITE_KILLER" 2>/dev/null || true

if [ $WRITE_STATUS -gt 128 ]; then
  echo "ERROR: timed out writing to cmd FIFO after 10s — runner is not reading. Is it still alive?" >&2
  exit 1
fi

# Read until OUR sentinel arrives. Anything else on the result FIFO — a stale
# sentinel from a timed-out command, a late READY, or a stray line — is
# discarded with a note instead of being returned as this command's output.
DEADLINE=$((SECONDS + TIMEOUT))
sentinel=""
while [ -z "$sentinel" ]; do
  REMAINING=$((DEADLINE - SECONDS))
  if [ "$REMAINING" -le 0 ]; then
    echo "ERROR: timed out waiting for response after ${TIMEOUT}s." >&2
    echo "The command may still be running in the session. Its late sentinel will be discarded automatically by the next call — but the runner processes commands serially, so either wait and retry with a longer timeout or restart the session." >&2
    exit 1
  fi
  if ! IFS= read -r -t "$REMAINING" line < "/tmp/pwsh_sess_${SESSION}_result"; then
    continue
  fi
  case "$line" in
    "DONE:${CMD_ID}:"*) sentinel="$line" ;;
    DONE:*)  echo "[discarded stale sentinel from an earlier timed-out command]" >&2 ;;
    READY)   ;;
    *)       echo "[discarded stray session output: $line]" >&2 ;;
  esac
done

rest="${sentinel#DONE:"${CMD_ID}":}"
IFS=':' read -r exitCode stdoutFile stderrFile lineCount <<< "$rest"

echo "exit=$exitCode lines=$lineCount"

if [ -n "$PATTERN" ]; then
  grep -i "$PATTERN" "$stdoutFile" 2>/dev/null
  echo "[Filtered view — full output preserved at $stdoutFile]"
elif [ "${lineCount:-0}" -le 100 ]; then
  cat "$stdoutFile" 2>/dev/null
else
  echo "[Showing first 20 of $lineCount lines — full output preserved at $stdoutFile. Read or grep that file directly; no need to re-run the command.]"
  head -20 "$stdoutFile" 2>/dev/null
fi

if [ "${exitCode}" != "0" ] && [ -s "$stderrFile" ]; then
  echo "--- stderr ---"
  cat "$stderrFile"
fi
