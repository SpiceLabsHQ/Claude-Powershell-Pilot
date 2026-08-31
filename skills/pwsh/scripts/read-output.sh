#!/bin/bash
# Usage: bash read-output.sh <sentinel> [grep_pattern]
# Parses the sentinel and reads stdout/stderr intelligently.
# Prints full stdout for small output, head+hint for large output,
# and always prints stderr when the exit code is non-zero.

SENTINEL="$1"
PATTERN="$2"

IFS=':' read -r _ _ exitCode stdoutFile stderrFile lineCount <<< "$SENTINEL"

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
