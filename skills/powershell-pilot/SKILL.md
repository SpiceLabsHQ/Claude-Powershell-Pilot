---
name: powershell-pilot
description: >
  Use when the user wants to run PowerShell (pwsh) commands on macOS or Linux,
  automate multi-step tasks that share session state, or authenticate to services
  (Azure, M365, Exchange Online, etc.) and run commands in the same authenticated
  session. Maintains persistent named sessions across multiple tool calls.
---

# PowerShell Pilot

Runs `pwsh` commands through a persistent background session. Session state
(variables, loaded modules, auth tokens) survives across commands. Multiple named
sessions run concurrently — use different names when tasks need different
permission levels.

## Environment

- **PowerShell version:** !`pwsh --version 2>/dev/null || echo "NOT INSTALLED"`
- **Installed modules:** !`pwsh -NoProfile -c "(Get-Module -ListAvailable | Select-Object -ExpandProperty Name | Sort-Object -Unique) -join ', '" 2>/dev/null || echo "NOT INSTALLED"`

If either value above shows `NOT INSTALLED`, stop and tell the user that `pwsh`
is not installed, then offer to install it:

- **macOS:** `brew install powershell`
- **Linux (Debian/Ubuntu):** follow the [Microsoft install guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux)

Do not attempt to start a session until `pwsh` is available.

## How it works

- Two named FIFOs per session carry commands in and sentinels out (no polling or sleep)
- Each command's stdout and stderr go to separate per-command temp files
- Sentinel format: `DONE:<exitCode>:<stdoutFile>:<stderrFile>:<lineCount>`
- Session state lives in `/tmp/pwsh_session_<name>.json`

Read only what you need. For large output (many lines), grep the file rather than
reading it entirely.

---

## Step 1 — Deploy the runner

Before starting any session, ensure the runner script is in place. Use the Read
tool to read `runner.ps1` from this skill's directory, then use the Write tool to
write it to `/tmp/pwsh_runner.ps1`. Do this once per conversation (skip if the
file already exists and the session was started in this conversation).

---

## Step 2 — Start a session

Choose a session name (default: `"default"`). Use a descriptive name when running
concurrent sessions with different permission levels (e.g., `"azure-admin"`).

```bash
SESSION="default"   # replace as needed
CMD_PIPE="/tmp/pwsh_sess_${SESSION}_cmd"
RESULT_PIPE="/tmp/pwsh_sess_${SESSION}_result"
STATE="/tmp/pwsh_session_${SESSION}.json"

# Skip if already running
if [ -f "$STATE" ]; then cat "$STATE"; exit 0; fi

rm -f "$CMD_PIPE" "$RESULT_PIPE"
mkfifo "$CMD_PIPE" "$RESULT_PIPE"
printf '{"name":"%s","cmdPipe":"%s","resultPipe":"%s"}\n' \
  "$SESSION" "$CMD_PIPE" "$RESULT_PIPE" > "$STATE"
echo "FIFOs created for session: $SESSION"
```

Then start the runner as a background task:

```bash
exec 3<>/tmp/pwsh_sess_<SESSION>_result && \
  pwsh -NoProfile -NonInteractive -File /tmp/pwsh_runner.ps1 \
       -SessionName <SESSION> \
       <>/tmp/pwsh_sess_<SESSION>_cmd 1>&3 \
       2>/tmp/pwsh_sess_<SESSION>.log
```

**Wait 3 seconds** after starting before sending the first command. PowerShell's
cold-start JIT on macOS/Linux takes 2–3 s; writing before it is ready causes the
write to block.

---

## Step 3 — Run a command

```bash
SESSION="default"
printf '%s\n' '<your command here>' > /tmp/pwsh_sess_${SESSION}_cmd
IFS= read -r -t 120 sentinel < /tmp/pwsh_sess_${SESSION}_result
echo "$sentinel"
```

Use `-t 120` (2 minutes) for regular commands. The read returns the moment the
command finishes — no sleep needed.

**Parse the sentinel:**

```bash
IFS=':' read -r _ exitCode stdoutFile stderrFile lineCount <<< "$sentinel"
```

**Read output based on line count:**

- `lineCount` ≤ 100 → read the full stdout file
- `lineCount` > 100 → grep or head/tail to find what you need
- `exitCode` ≠ 0 → always read the stderr file

```bash
# Full read (small output)
cat "$stdoutFile"

# Targeted read (large output)
grep -i "pattern" "$stdoutFile"
head -20 "$stdoutFile"

# Error output
cat "$stderrFile"
```

---

## Step 4 — Authenticate (when required)

Only send auth commands after getting explicit user approval. The user needs to
know a browser window or device-code prompt is about to appear.

**Ask permission** using AskUserQuestion before sending any auth command:

- Question: "To proceed, I need to authenticate to [service]. This will open your
  browser (or display a device code). Approve?"
- Options: Approve / Cancel

**If approved**, send the auth command with a 5-minute timeout:

```bash
SESSION="default"
printf '%s\n' '<auth command>' > /tmp/pwsh_sess_${SESSION}_cmd
IFS= read -r -t 300 sentinel < /tmp/pwsh_sess_${SESSION}_result
echo "$sentinel"
```

**After auth**, read stdout to check for device codes or confirmation messages,
then read stderr to confirm no errors.

**Common auth commands by service:**

| Service           | Command                          |
| ----------------- | -------------------------------- |
| Azure             | `Connect-AzAccount`              |
| Microsoft Graph   | `Connect-MgGraph -Scopes "..."`  |
| Exchange Online   | `Connect-ExchangeOnline`         |
| SharePoint Online | `Connect-PnPOnline -Interactive` |

Install missing modules in-session: `Install-Module <name> -Scope CurrentUser -Force`

---

## Step 5 — Close a session

```bash
SESSION="default"
printf '%s\n' '__EXIT__' > /tmp/pwsh_sess_${SESSION}_cmd
sleep 1
rm -f /tmp/pwsh_sess_${SESSION}_cmd \
      /tmp/pwsh_sess_${SESSION}_result \
      /tmp/pwsh_sess_${SESSION}.log \
      /tmp/pwsh_session_${SESSION}.json \
      /tmp/pwsh_${SESSION}_stdout_*.txt \
      /tmp/pwsh_${SESSION}_stderr_*.txt
```

---

## Multi-session example

Start a read-only session and a privileged session side by side:

```bash
# Session 1: read-only queries
SESSION="readonly"
# ... start as above ...

# Session 2: admin operations (requires separate auth approval)
SESSION="admin"
# ... start as above, request auth separately ...
```

Each session has its own FIFOs, output files, and auth state. They do not share
variables or tokens.

---

## Troubleshooting

| Symptom                         | Cause                                    | Fix                                      |
| ------------------------------- | ---------------------------------------- | ---------------------------------------- |
| Write to cmd pipe hangs         | Session not started yet                  | Check state file exists; wait 3 s        |
| `read` times out                | Command took longer than `-t` value      | Retry with higher `-t`; check runner log |
| Exit code 1, empty stderr       | Module not installed                     | Run `Install-Module` in-session          |
| Sentinel never arrives          | Runner crashed                           | Check `/tmp/pwsh_sess_<name>.log`        |
| Auth command hangs indefinitely | Browser opened but `-t` too low          | Use `-t 300` for all auth commands       |
