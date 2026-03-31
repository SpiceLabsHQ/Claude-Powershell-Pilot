---
name: pwsh
description: >
  Use when the user wants to run PowerShell (pwsh) commands on macOS or Linux,
  automate multi-step tasks that share session state, or authenticate to services
  (Azure, M365, Exchange Online, etc.) and run commands in the same authenticated
  session. Maintains persistent named sessions across multiple tool calls.
allowed-tools: Bash(pwsh --version), Bash(bash */pwsh/scripts/*)
---

# PowerShell Pilot

Runs `pwsh` commands through a persistent background session. Session state
(variables, loaded modules, auth tokens) survives across commands. Multiple named
sessions run concurrently — use different names when tasks need different
permission levels.

## Environment

- **PowerShell version:** !`pwsh --version`
- **Installed modules:** !`bash ${CLAUDE_SKILL_DIR}/scripts/get-modules.sh`
- **Auth status:**
  !`bash ${CLAUDE_SKILL_DIR}/scripts/get-auth-status.sh`

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

**Verify the runner started cleanly** by sending a test command after 3 seconds.
PowerShell's cold-start JIT on macOS/Linux takes 2–3 s; writing before it is
ready causes the write to block.

```bash
echo '$PSVersionTable.PSVersion.ToString()' | bash ${CLAUDE_SKILL_DIR}/scripts/run-command.sh <SESSION> 15
```

If this times out or returns a non-zero exit code, the runner did not start. Stop
the session, check for error output in `/tmp/pwsh_sess_<SESSION>.log`, and restart
before proceeding.

---

## Step 2 — Run a command

Use `run-command.sh` — it sends the command and reads the output in a single
script call. This is the **required** pattern; do not use `$()` command
substitution or pipe between `send-command.sh` and `read-output.sh` inline,
because compound shell expressions are flagged for user approval even when
the scripts themselves are pre-approved.

```bash
echo '<pwsh command>' | bash ${CLAUDE_SKILL_DIR}/scripts/run-command.sh <SESSION>
```

For long-running commands (e.g., large data exports), pass a timeout in seconds:

```bash
echo '<pwsh command>' | bash ${CLAUDE_SKILL_DIR}/scripts/run-command.sh <SESSION> 300
```

For large output, pass a grep pattern as the third argument:

```bash
echo '<pwsh command>' | bash ${CLAUDE_SKILL_DIR}/scripts/run-command.sh <SESSION> 120 "search pattern"
```

`run-command.sh` automatically:

- Prints full stdout when output is ≤ 100 lines
- Prints the first 20 lines and a reminder to grep when output exceeds 100 lines
- Always prints stderr when the exit code is non-zero

---

## Step 3 — Authenticate (when required)

**Check the Auth status from the Environment section above before doing anything.**
If a service already shows an authenticated account, tell the user which account
is active and proceed without re-authenticating.

**If not connected**, use `auth-device-code.sh`. Do NOT use `run-command.sh` for
authentication — it buffers all output until the command finishes, so the device
code only becomes visible after the 120-second Microsoft timeout expires.
`auth-device-code.sh` runs auth in a separate process where stdout streams to a
file in real time, making the device code available within seconds.

**Auth flow:**

1. Start auth in the background (`run_in_background: true`). Do NOT add a
   `sleep` prefix — `auth-device-code.sh` handles timing internally:

    ```bash
    echo '<auth command>' | bash ${CLAUDE_SKILL_DIR}/scripts/auth-device-code.sh <SESSION>
    ```

2. Use `TaskOutput` with `block: false` after 10 seconds to read the task output.
   It will contain a line like:

   `To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code XXXXXXXX to authenticate.`

3. Immediately tell the user:

   > To authenticate, open **<https://microsoft.com/devicelogin>** in your browser
   > and enter the code: **XXXXXXXX**

4. Use `TaskOutput` with `block: true` and `timeout: 300000` to wait for the
   task to finish. Do NOT poll the output file manually — that file belongs to
   the internal `auth-device-code.sh` process and is deleted when auth completes.
   The task output ends with either `AUTH_COMPLETE` or `AUTH_FAILED`.

5. After `AUTH_COMPLETE`, establish the connection in the session using the
   silent variant — tokens are now cached so this completes instantly:

    ```bash
    echo '<silent connect command>' | bash ${CLAUDE_SKILL_DIR}/scripts/run-command.sh <SESSION> 30
    ```

**Auth commands by service:**

| Service           | Device code command                                          | Silent reconnect after auth          |
| ----------------- | ------------------------------------------------------------ | ------------------------------------ |
| Azure             | `Connect-AzAccount -UseDeviceAuthentication`                 | `Get-AzContext` (auto from ~/.Azure) |
| Microsoft Graph   | `Connect-MgGraph -UseDeviceAuthentication -Scopes "..."`     | `Connect-MgGraph -NoWelcome`         |
| Exchange Online   | `Connect-ExchangeOnline -Device`                             | `Connect-ExchangeOnline -Device`     |
| SharePoint Online | `Connect-PnPOnline -DeviceLogin`                             | `Connect-PnPOnline -DeviceLogin`     |

Install missing modules in-session:

```bash
echo 'Install-Module <name> -Scope CurrentUser -Force' | bash ${CLAUDE_SKILL_DIR}/scripts/run-command.sh <SESSION> 120
```

**Microsoft Graph — beta API resources:** The `Get-Mg*` cmdlets only cover v1.0 Graph
APIs. Many resources (device health scripts, compliance policies, advanced Intune
data, etc.) are beta-only and have no matching cmdlet. If `Get-Mg*` returns
"not recognized" for a resource that should exist, query the beta endpoint directly:

```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/<resource-path>"
```

Do not retry module imports or search for alternative cmdlets — if the resource is
not in v1.0, the cmdlet simply does not exist and `Invoke-MgGraphRequest` is the
correct approach.

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

| Symptom                         | Cause                               | Fix                                           |
| ------------------------------- | ----------------------------------- | --------------------------------------------- |
| Write to cmd pipe hangs         | Session not started yet             | Check state file exists; wait 3 s             |
| `run-command.sh` times out      | Command exceeded timeout            | Retry with higher timeout argument            |
| Exit code 1, empty stderr       | Module not installed                | Run `Install-Module` in-session               |
| `Get-Mg*` cmdlet not recognized | Resource is beta-only in Graph      | Use `Invoke-MgGraphRequest` with beta URL     |
| Sentinel never arrives          | Runner crashed                      | Check `/tmp/pwsh_sess_<name>.log`             |
| Auth command times out          | Device code not entered in time     | Use 300 s timeout; re-run to get a new code   |
