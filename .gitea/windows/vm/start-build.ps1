# Start build.ps1 as a scheduled task in dev's session and return at once.
# A task keeps running if the SSH connection drops; a child of sshd would not.
# Output goes to build.log; run-windows-test.sh polls it for "BUILD-EXIT".
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = "$here\build.log"
Remove-Item $log -ErrorAction SilentlyContinue
$cmd = "$here\build.cmd"
@"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$here\build.ps1" > "$log" 2>&1
"@ | Set-Content -Encoding ASCII $cmd
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$cmd`""
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName 'KanbanCodeE2EBuild' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'KanbanCodeE2EBuild'
"build started"
