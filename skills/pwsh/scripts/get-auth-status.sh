#!/bin/bash
# Checks auth status for Microsoft Graph, Azure, and Exchange Online.
# Wraps the entire pwsh invocation in a hard timeout so a slow cold-start
# cannot hang the skill's environment section indefinitely.

TIMEOUT=45
tmpout=$(mktemp)

pwsh -NoProfile -c '
$WarningPreference = "SilentlyContinue"
$results = @()

# Microsoft Graph — use a job with timeout: silent reconnect (cached tokens) finishes in ms;
# interactive auth (browser popup) hangs. 5s timeout safely distinguishes the two.
try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop 3>$null
    $job = Start-Job -ScriptBlock {
        $WarningPreference = "SilentlyContinue"
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop 3>$null
        Connect-MgGraph -UseDeviceAuthentication -ErrorAction SilentlyContinue 3>$null | Out-Null
        $ctx = Get-MgContext
        if ($ctx) { $ctx.Account } else { "Not authenticated" }
    }
    $done = Wait-Job $job -Timeout 5
    if ($done) {
        $account = Receive-Job $job 2>$null | Select-Object -Last 1
        $results += "Microsoft Graph: " + $account
    } else {
        Stop-Job $job
        Remove-Job $job -Force
        $results += "Microsoft Graph: Not authenticated"
    }
} catch {
    $results += "Microsoft Graph: Module not installed"
}

# Azure — Get-AzContext reads ~/.Azure/ and works across processes
try {
    Import-Module Az.Accounts -ErrorAction Stop 3>$null
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $results += "Azure: " + $(if ($ctx -and $ctx.Account) { $ctx.Account.Id } else { "Not authenticated" })
} catch {
    $results += "Azure: Module not installed"
}

# Exchange Online — no silent reconnect available; can only detect an already-active in-process connection
try {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop 3>$null
    $info = Get-ConnectionInformation -ErrorAction SilentlyContinue
    $results += "Exchange Online: " + $(if ($info -and $info.State -eq "Connected") { $info.UserPrincipalName } else { "Not authenticated" })
} catch {
    $results += "Exchange Online: Module not installed"
}

$results -join "`n"
' >"$tmpout" 2>/dev/null &
PID=$!

( sleep $TIMEOUT; kill "$PID" 2>/dev/null ) &
KILLER=$!

wait "$PID"
STATUS=$?

kill "$KILLER" 2>/dev/null
wait "$KILLER" 2>/dev/null || true

if [ $STATUS -gt 128 ]; then
  rm -f "$tmpout"
  echo "TIMED OUT: auth status check took more than ${TIMEOUT}s (pwsh installed but slow to cold-start)"
elif [ $STATUS -ne 0 ]; then
  rm -f "$tmpout"
  echo "pwsh not installed"
else
  cat "$tmpout"
  rm -f "$tmpout"
fi
