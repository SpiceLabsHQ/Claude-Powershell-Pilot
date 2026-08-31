# PowerShell Pilot session runner
# Reads commands from stdin (cmd FIFO), writes sentinel to stdout (result FIFO).
# Each command's stdout and stderr go to separate per-command temp files so
# Claude can grep large output without loading it entirely.
#
# Startup protocol:
#   1. This script writes "READY\n" to stdout before entering the command loop.
#   2. The caller must read that line via wait-ready.sh before issuing commands.
#      Skipping this step causes a race: commands written before ReadLine() is
#      reached are buffered in the kernel pipe and the caller's read times out,
#      leaving a stale sentinel in the result FIFO that desynchronises all
#      subsequent commands.
#
# Sentinel format: DONE:<exitCode>:<stdoutFile>:<stderrFile>:<lineCount>
# Send __EXIT__ to terminate the session.

param([string]$SessionName = "default")

# Suppress ANSI color codes — output goes to files, not a terminal
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSStyle.OutputRendering = [System.Management.Automation.OutputRendering]::PlainText
}

# Diagnostics: log startup timestamp so the log is never silently empty.
[Console]::Error.WriteLine("$(Get-Date -Format 'HH:mm:ss') runner.ps1 starting (session=$SessionName, pid=$PID)")
[Console]::Error.Flush()

# Signal readiness. wait-ready.sh blocks until it reads this line.
# This must be the very first write to stdout.
[Console]::Out.WriteLine("READY")
[Console]::Out.Flush()

[Console]::Error.WriteLine("$(Get-Date -Format 'HH:mm:ss') runner.ps1 ready — entering command loop")
[Console]::Error.Flush()

$cmdCount = 0

while ($true) {
    $cmd = [Console]::In.ReadLine()
    if ($null -eq $cmd -or $cmd -eq '__EXIT__') { break }
    $cmd = $cmd.Trim()
    if ($cmd -eq '') { continue }

    $cmdCount++
    $stdoutFile = "/tmp/pwsh_${SessionName}_stdout_${cmdCount}.txt"
    $stderrFile = "/tmp/pwsh_${SessionName}_stderr_${cmdCount}.txt"
    $exitCode   = 0

    # Reset so native-command exit codes are detectable
    $global:LASTEXITCODE = $null

    try {
        $ev = @()
        $rawOutput = Invoke-Expression $cmd -ErrorVariable ev -ErrorAction Continue
        $stdout = if ($rawOutput) { ($rawOutput | Out-String).TrimEnd() } else { '' }
        $stderr = if ($ev)        { ($ev | ForEach-Object { $_.ToString() }) -join "`n" } else { '' }

        if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) {
            $exitCode = $global:LASTEXITCODE
        } elseif ($ev) {
            $exitCode = 1
        }
    } catch {
        $stdout   = ''
        $stderr   = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
        $exitCode = 1
    }

    [System.IO.File]::WriteAllText($stdoutFile, $stdout)
    [System.IO.File]::WriteAllText($stderrFile, $stderr)
    $lineCount = if ($stdout) { ($stdout -split "`n").Count } else { 0 }

    [Console]::Out.WriteLine("DONE:${exitCode}:${stdoutFile}:${stderrFile}:${lineCount}")
    [Console]::Out.Flush()
}
