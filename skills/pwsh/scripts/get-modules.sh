#!/bin/bash
# Lists installed PowerShell modules with a hard timeout.
# Exits with:
#   "TIMED OUT: ..." if pwsh is installed but too slow (killed by signal, status > 128)
#   "NOT INSTALLED"  if pwsh is not found or returns a non-zero exit
#   module list      on success

TIMEOUT=30
tmpout=$(mktemp)

pwsh -NoProfile -c "(Get-Module -ListAvailable | Select-Object -ExpandProperty Name | Sort-Object -Unique) -join ', '" >"$tmpout" 2>/dev/null &
PID=$!

( sleep $TIMEOUT; kill "$PID" 2>/dev/null ) &
KILLER=$!

wait "$PID"
STATUS=$?

kill "$KILLER" 2>/dev/null
wait "$KILLER" 2>/dev/null || true

if [ $STATUS -gt 128 ]; then
  rm -f "$tmpout"
  echo "TIMED OUT: pwsh took more than ${TIMEOUT}s to list modules (installed but slow to cold-start)"
elif [ $STATUS -ne 0 ]; then
  rm -f "$tmpout"
  echo "NOT INSTALLED"
else
  cat "$tmpout"
  rm -f "$tmpout"
fi
