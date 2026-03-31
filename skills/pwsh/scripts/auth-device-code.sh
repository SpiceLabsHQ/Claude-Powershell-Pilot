#!/bin/bash
# Run an auth command in a fresh pwsh process and stream the device code immediately.
# Auth runs outside the session FIFO so stdout is written to a file in real time.
# The auth command is read from stdin.
#
# Usage: echo '<auth command>' | bash auth-device-code.sh <SESSION>
#
# Output:
#   Prints the device code line as soon as it appears (~3s after start)
#   Prints AUTH_COMPLETE or AUTH_FAILED when the user finishes (or times out)
#
# After AUTH_COMPLETE, reconnect in the session with the silent variant:
#   Connect-MgGraph -NoWelcome    (Graph)
#   Get-AzContext                 (Azure — context persists to ~/.Azure/ automatically)

SESSION="${1:-default}"
AUTH_CMD=$(cat)
OUTPUT_FILE="/tmp/pwsh_auth_${SESSION}.txt"

rm -f "$OUTPUT_FILE"

# Run auth in a separate pwsh process — stdout streams to file in real time
pwsh -NoProfile -c "
\$WarningPreference = 'SilentlyContinue'
${AUTH_CMD} 3>\$null
" > "$OUTPUT_FILE" 2>/dev/null &
PWSH_PID=$!

# Poll until device code line appears (pwsh cold-start + auth call takes ~3s)
for i in $(seq 1 30); do
    sleep 1
    if [ -s "$OUTPUT_FILE" ]; then
        cat "$OUTPUT_FILE"
        break
    fi
    if ! kill -0 "$PWSH_PID" 2>/dev/null; then
        break
    fi
done

# Block until auth completes (user enters the code) or the process exits
wait "$PWSH_PID"
EXIT_CODE=$?

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "AUTH_COMPLETE"
else
    echo "AUTH_FAILED"
fi

rm -f "$OUTPUT_FILE"
exit "$EXIT_CODE"
