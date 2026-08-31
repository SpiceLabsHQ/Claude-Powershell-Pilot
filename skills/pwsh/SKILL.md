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

If either value shows a background task ID (`Command running in background with
ID: ...`), the env check is still running. Wait for both tasks:

```text
TaskOutput(task_id: <ID>, block: true, timeout: 60000)
```

If `retrieval_status` is `timeout`, read the output file at the path shown in
the task message. If the file is empty or the task later fails with no output,
treat it as `TIMED OUT` and proceed to start a session — the runner uses
`-NoProfile` and starts faster than the env checks.

If either value shows `NOT INSTALLED`, stop and tell the user that `pwsh` is not
installed, then offer to install it:

- **macOS:** `brew install powershell`
- **Linux (Debian/Ubuntu):** follow the [Microsoft install guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux)

Do not attempt to start a session until `pwsh` is available.

If either value shows `TIMED OUT`, `pwsh` is installed but took more than the
allowed time to cold-start. Proceed to start a session normally — the runner
uses `-NoProfile` which is faster than the environment check scripts.

## How it works

- Two named FIFOs per session carry commands in and sentinels out (no polling or sleep)
- `runner.ps1` emits `READY` on the result FIFO before entering its command loop; `wait-ready.sh` blocks until that signal arrives
- Commands travel base64-encoded on one line as `RUN:<id>:<base64>`, so multi-line scripts work; the runner answers `DONE:<id>:<exitCode>:<stdoutFile>:<stderrFile>:<lineCount>`
- The per-command id means `run-command.sh` only accepts its own result — stale sentinels from timed-out commands and stray output are discarded, never returned as the wrong command's output
- Each command's stdout and stderr go to separate per-command temp files that persist until the session stops, so large results are never lost
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

**Wait for the runner to signal readiness** before issuing any commands.
`runner.ps1` emits a `READY` line on the result FIFO as its very first act.
`wait-ready.sh` blocks until that line arrives (default 60 s timeout):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-ready.sh <SESSION> 60
```

**Do not skip this step.** PowerShell's cold-start on macOS/Linux with many
installed modules can take 10–30 s. If you write a command before `ReadLine()`
is reached, the kernel buffers it silently and your read times out — leaving a
stale sentinel in the result FIFO that desynchronises every subsequent command.

If `wait-ready.sh` times out:

- If the **log has content** — pwsh started but hung during initialization;
  check the log for errors and restart.
- If the **log is empty** — the .NET runtime never executed `runner.ps1` at all.
  Run `ps aux | grep pwsh` and look for processes in `U` (uninterruptible wait)
  state. This is a machine-level issue. Tell the user:
  > `pwsh` is not responding — multiple processes appear to be stuck. Try
  > killing them with `pkill -9 pwsh`, then run `brew reinstall powershell` to
  > clear stale .NET caches. If processes remain in U-state, a reboot is needed.
  Do not continue attempting to start a session until `pwsh --version` returns
  normally.

**After a command timeout:** the session stays usable. The timed-out command's
late sentinel is discarded automatically by the next `run-command.sh` call, so
output can no longer desynchronise. But the runner processes commands serially —
a timed-out command is usually still running and the next command waits behind
it. For a command that legitimately needs longer, re-run with a bigger timeout;
if it is genuinely hung, stop and restart the session.

**Runner lifetime:** The runner stays alive indefinitely — there is no idle timeout.
It exits when `stop-session.sh` kills the runner process, when the PowerShell
process crashes, or when the background task is killed externally. Once started
successfully, the session remains valid across any number of tool calls until
explicitly stopped.

**Checking liveness mid-session:** Use `check-session.sh` before a command if you
suspect the runner may have died (e.g., after a long gap between commands or after
a previous command timed out):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-session.sh <SESSION>
```

Exits 0 and prints `alive: pid=<PID>` if the runner is live; exits 1 with a `dead:`
message otherwise. `run-command.sh` also checks liveness automatically and returns
exit code 2 with an explicit error if the runner is not running.

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

**Multi-line scripts** are fully supported — the whole of stdin is sent as one
unit, so `try/catch`, loops, and here-strings work as they would interactively.
Use a heredoc:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/run-command.sh <SESSION> 120 <<'EOF'
try {
    $r = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users"
    $r.value | Select-Object displayName, userPrincipalName
} catch {
    Write-Error "request failed: $_"
}
EOF
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
- Prints the first 20 lines plus the path of the full-output file when output
  exceeds 100 lines
- Always prints stderr when the exit code is non-zero

**Large or expensive results are never lost.** Every command's complete stdout
is preserved in the temp file named in the truncation notice
(`/tmp/pwsh_<session>_stdout_<n>.txt`). When a result is truncated, read or
grep that file directly — do not re-run an expensive query just to see more of
its output. The files persist until `stop-session.sh` runs.

---

## Step 3 — Authenticate (when required)

**Check the Auth status from the Environment section above before doing anything.**
If a service already shows an authenticated account, tell the user which account
is active and proceed without re-authenticating.

**Pick the auth pattern by where the module caches its tokens.** This is the
one fact that determines everything else:

- **Disk-cached modules** (Azure `Az`, Microsoft Graph SDK) persist tokens to
  the user profile (`~/.Azure`, MSAL cache). Authenticate in a **separate
  process** with `auth-device-code.sh`, then reconnect silently in the session —
  the session finds the cached token on disk.
- **In-process modules** (`ExchangeOnlineManagement` — both Exchange Online and
  Security & Compliance — and PnP without persistence) keep the connection in
  process memory only. Authenticating in a separate process is worthless: the
  session cannot see that connection and will demand its own auth. These MUST
  authenticate **inside the session** using the in-session flow below.

### Flow A — disk-cached modules (separate process)

Do NOT use `run-command.sh` for this flow — it buffers all output until the
command finishes, so the device code only becomes visible after the 120-second
Microsoft timeout expires. `auth-device-code.sh` runs auth in a separate process
where stdout streams to a file in real time, making the device code available
within seconds.

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

### Flow B — in-process modules (inside the session)

Run the connect command in the session as a long-timeout **background** Bash
call, redirecting all of its streams to a progress file so the device code (or
any prompt text) is visible in real time while the command is still blocking:

1. Start the connect command as a background task (`run_in_background: true`):

    ```bash
    echo 'Connect-ExchangeOnline -Device *> /tmp/pwsh_auth_progress.txt' | bash ${CLAUDE_SKILL_DIR}/scripts/run-command.sh <SESSION> 300
    ```

2. After ~10 seconds, read `/tmp/pwsh_auth_progress.txt` (plain file read — not
   a session command) and relay the device code to the user:

   > To authenticate, open **<https://microsoft.com/devicelogin>** in your browser
   > and enter the code: **XXXXXXXX**

3. Wait for the background task to finish, then confirm with a quick session
   command (`Get-ConnectionInformation` for EXO/S&C).

For a module whose connect command opens a **browser** instead of printing a
device code (e.g. `Connect-IPPSSession -UserPrincipalName <upn>`), the same
background pattern applies — tell the user to watch for the browser window, and
check the progress file if nothing appears.

**Auth commands by service:**

| Service               | Token cache | Interactive auth command                                          | Silent reconnect after auth          |
| --------------------- | ----------- | ----------------------------------------------------------------- | ------------------------------------ |
| Azure                 | disk        | `Connect-AzAccount -UseDeviceAuthentication` (Flow A)             | `Get-AzContext` (auto from ~/.Azure) |
| Microsoft Graph       | disk        | `Connect-MgGraph -UseDeviceAuthentication -Scopes "..."` (Flow A) | `Connect-MgGraph -NoWelcome`         |
| Exchange Online       | in-process  | `Connect-ExchangeOnline -Device` (Flow B)                         | none — reconnect is a fresh Flow B   |
| Security & Compliance | in-process  | `Connect-IPPSSession -UserPrincipalName <upn>` (Flow B, browser)  | none — reconnect is a fresh Flow B   |
| SharePoint Online     | in-process  | `Connect-PnPOnline -DeviceLogin` (Flow B)                         | none — reconnect is a fresh Flow B   |

**Security & Compliance notes:** `Connect-IPPSSession` has no `-Device`
parameter (as of `ExchangeOnlineManagement` 3.9.x) — device-code auth cannot be
used at all; the `-UserPrincipalName` browser flow above is the interactive
path, and a certificate + app registration (`-AppId -CertificateThumbprint
-Organization`) is the unattended one. Do not try to feed it an Azure CLI token
(`az account get-access-token --resource https://ps.compliance.protection.outlook.com`
passed as `-AccessToken`) — the Azure CLI's first-party app is not authorized
for that resource and the connect fails with `UnAuthorized`.

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

| Symptom                                     | Cause                                    | Fix                                                                                    |
| ------------------------------------------- | ---------------------------------------- | -------------------------------------------------------------------------------------- |
| `run-command.sh` exits 2, "not running"     | Runner died or never started             | Run `check-session.sh`; restart with `run-session.sh`                                  |
| `wait-ready.sh` times out, log has content  | pwsh hung during initialization          | Check log for errors; stop and restart session                                         |
| `wait-ready.sh` times out, log is empty     | .NET runtime stuck before script ran     | `pkill -9 pwsh`; `brew reinstall powershell`; reboot if U-state                        |
| Env section shows `TIMED OUT`               | pwsh installed but slow to cold-start    | Proceed normally; runner uses `-NoProfile` and starts faster                           |
| Write to cmd pipe hangs                     | Runner dead, no FIFO reader              | `run-command.sh` times out the write after 10 s automatically                          |
| Commands return wrong results after restart | Old runner consuming FIFO commands       | Always use `stop-session.sh` before restarting; it kills the PID                       |
| `run-command.sh` times out                  | Command exceeded timeout                 | Session stays usable; command may still be running — wait or restart                   |
| `[discarded stale sentinel ...]` printed    | Earlier command timed out, then finished | Informational only; the result shown belongs to your command                           |
| Device code never appears in progress file  | Module wrote to console, not a stream    | Run any session command — stray lines print as `[discarded stray session output: ...]` |
| Exit code 1, empty stderr                   | Module not installed                     | Run `Install-Module` in-session                                                        |
| `Get-Mg*` cmdlet not recognized             | Resource is beta-only in Graph           | Use `Invoke-MgGraphRequest` with beta URL                                              |
| Sentinel never arrives                      | Runner crashed                           | Check `/tmp/pwsh_sess_<name>.log`                                                      |
| Auth command times out                      | Device code not entered in time          | Use 300 s timeout; re-run to get a new code                                            |
