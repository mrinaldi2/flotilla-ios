# Installs Gravity Lens on Windows as a scheduled task that starts at sign-in
# and restarts if it stops (for example when Tailscale was not up yet).
#
#   .\install.ps1                  install or update
#   .\install.ps1 -WithFiles       also share your user folder with the phone's file browser
#   .\install.ps1 -WithoutFiles    turn the file browser off again
#   .\install.ps1 -Uninstall       remove it
#
# Needs Python 3.9+ (the py launcher or python on PATH). No admin rights needed.
[CmdletBinding()]
param(
    [switch]$WithFiles,
    [switch]$WithoutFiles,
    [switch]$Uninstall
)
$ErrorActionPreference = "Stop"

$TaskName = "Gravity Lens"
$HomeDir = Join-Path $env:USERPROFILE ".gravity-lens"
$ThumbDir = Join-Path $env:LOCALAPPDATA "GravityLens"
$Log = Join-Path $HomeDir "lens.log"

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $HomeDir, $ThumbDir -ErrorAction SilentlyContinue
    Write-Host "Gravity Lens removed."
    exit 0
}

# pythonw.exe runs without a console window; its messages go to the log file.
function Find-Pythonw {
    $candidates = @(
        @{ Exe = "py"; Args = @("-3") },
        @{ Exe = "python"; Args = @() }
    )
    foreach ($candidate in $candidates) {
        if (-not (Get-Command $candidate.Exe -ErrorAction SilentlyContinue)) { continue }
        $pyArgs = $candidate.Args + @("-c", "import sys; print(sys.executable if sys.version_info >= (3, 9) else '')")
        # The Microsoft Store stub prints nothing useful, so the path check below catches it.
        $python = (& $candidate.Exe @pyArgs 2>$null | Select-Object -First 1)
        if ($python -and (Test-Path $python)) {
            $pythonw = Join-Path (Split-Path $python) "pythonw.exe"
            if (Test-Path $pythonw) { return $pythonw }
        }
    }
    throw "Python 3.9 or later was not found. Install it with: winget install Python.Python.3.12"
}

$Source = $PSScriptRoot
New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null
Copy-Item (Join-Path $Source "gravity_lens.py"), (Join-Path $Source "gravity_files.py") $HomeDir -Force

# UTF-8 without a byte-order mark: Windows PowerShell's -Encoding UTF8 would add one.
function Write-Config([string]$Text) {
    [IO.File]::WriteAllText($Config, $Text, (New-Object Text.UTF8Encoding $false))
}

$Config = Join-Path $HomeDir "config.json"
if ($WithFiles) {
    Write-Config "{`n  `"files`": {`"enabled`": true, `"roots`": [`"~`"]}`n}"
    Write-Host "File browsing: on for your user folder (edit roots in $Config). AppData is never shared."
} elseif ($WithoutFiles) {
    Write-Config "{`n  `"files`": {`"enabled`": false}`n}"
    Write-Host "File browsing: off."
}

$Pythonw = Find-Pythonw
$Script = Join-Path $HomeDir "gravity_lens.py"
$Action = New-ScheduledTaskAction -Execute $Pythonw -Argument "`"$Script`" --log `"$Log`"" -WorkingDirectory $HomeDir
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal `
    -Description "Read-only view of bots' work for the Flotilla phone app." -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 3
Write-Host "Gravity Lens installed: it starts at sign-in and restarts if it stops."
Write-Host "Python: $Pythonw"
Write-Host "Log:    $Log"
if (Test-Path $Log) { Get-Content $Log -Tail 5 }
Write-Host "Check it from the phone's tailnet with: curl http://<this PC's Tailscale IP>:49778/health"
