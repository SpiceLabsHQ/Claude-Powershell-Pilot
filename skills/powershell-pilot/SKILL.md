---
name: powershell-pilot
description: >
  Use when the user wants to run PowerShell (pwsh) commands on macOS or Linux,
  automate multi-step tasks that share session state, or authenticate to services
  (Azure, M365, Exchange Online, etc.) and run commands in the same authenticated
  session. Maintains persistent named sessions across multiple tool calls.
allowed-tools: Bash(pwsh --version), Bash(bash */powershell-pilot/scripts/*)
---

# PowerShell Pilot

Runs `pwsh` commands through a persistent background session. Session state
(variables, loaded modules, auth tokens) survives across commands. Multiple named
sessions run concurrently — use different names when tasks need different
permission levels.

## Environment

- **PowerShell version:** !`pwsh --version`
- **Installed modules:** !`bash ${CLAUDE_SKILL_DIR}/scripts/get-modules.sh`

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

---

## Step 1 — Start a session

Choose a session name (default: `"default"`). Use a descriptive name when running
concurrent sessions with different permission levels (e.g., `"azure-admin"`).

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/start-session.sh <SESSION>
```

Then start the runner as a background task (use `run_in_background: true`):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/run-session.sh <SESSION>
```

**Wait 3 seconds** after starting before sending the first command. PowerShell's
cold-start JIT on macOS/Linux takes 2–3 s; writing before it is ready causes the
write to block.

---

## Step 2 — Run a command

Pipe the PowerShell command into `send-command.sh`. Use a timeout appropriate for
the expected runtime (default 120 s):

```bash
echo '<pwsh command>' | bash ${CLAUDE_SKILL_DIR}/scripts/send-command.sh <SESSION>
```

For long-running commands (e.g., large data exports):

```bash
echo '<pwsh command>' | bash ${CLAUDE_SKILL_DIR}/scripts/send-command.sh <SESSION> 300
```

The script prints a sentinel line when the command finishes. Pass it directly to
`read-output.sh`:

```bash
sentinel=$(echo '<pwsh command>' | bash ${CLAUDE_SKILL_DIR}/scripts/send-command.sh <SESSION>)
bash ${CLAUDE_SKILL_DIR}/scripts/read-output.sh "$sentinel"
```

For large output, pass a grep pattern to avoid loading everything:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/read-output.sh "$sentinel" "search pattern"
```

`read-output.sh` automatically:

- Prints full stdout when output is ≤ 100 lines
- Prints the first 20 lines and a reminder to grep when output exceeds 100 lines
- Always prints stderr when the exit code is non-zero

---

## Step 3 — Authenticate (when required)

Only send auth commands after getting explicit user approval. The user needs to
know a browser window or device-code prompt is about to appear.

**Ask permission** using AskUserQuestion before sending any auth command:

- Question: "To proceed, I need to authenticate to [service]. This will open your
  browser (or display a device code). Approve?"
- Options: Approve / Cancel

**If approved**, send with a 5-minute timeout:

```bash
sentinel=$(echo '<auth command>' | bash ${CLAUDE_SKILL_DIR}/scripts/send-command.sh <SESSION> 300)
bash ${CLAUDE_SKILL_DIR}/scripts/read-output.sh "$sentinel"
```

**Common auth commands by service:**

| Service           | Command                          |
| ----------------- | -------------------------------- |
| Azure             | `Connect-AzAccount`              |
| Microsoft Graph   | `Connect-MgGraph -Scopes "..."`  |
| Exchange Online   | `Connect-ExchangeOnline`         |
| SharePoint Online | `Connect-PnPOnline -Interactive` |

Install missing modules in-session:

```bash
echo 'Install-Module <name> -Scope CurrentUser -Force' | bash ${CLAUDE_SKILL_DIR}/scripts/send-command.sh <SESSION> 120
```

---

## Step 4 — Close a session

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/stop-session.sh <SESSION>
```

---

## Multi-session example

Start a read-only session and a privileged session side by side:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/start-session.sh readonly
bash ${CLAUDE_SKILL_DIR}/scripts/run-session.sh readonly   # run_in_background: true

bash ${CLAUDE_SKILL_DIR}/scripts/start-session.sh admin
bash ${CLAUDE_SKILL_DIR}/scripts/run-session.sh admin      # run_in_background: true
```

Each session has its own FIFOs, output files, and auth state. They do not share
variables or tokens.

---

## Troubleshooting

| Symptom                         | Cause                               | Fix                                      |
| ------------------------------- | ----------------------------------- | ---------------------------------------- |
| Write to cmd pipe hangs         | Session not started yet             | Check state file exists; wait 3 s        |
| `send-command.sh` times out     | Command exceeded timeout            | Retry with higher timeout argument       |
| Exit code 1, empty stderr       | Module not installed                | Run `Install-Module` in-session          |
| Sentinel never arrives          | Runner crashed                      | Check `/tmp/pwsh_sess_<name>.log`        |
| Auth command times out          | Browser not completed in time       | Use 300 s timeout for all auth commands  |
