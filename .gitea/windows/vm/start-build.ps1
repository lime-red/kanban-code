# Start build.ps1 as a scheduled task in dev's session and return at once.
# A task keeps running if the SSH connection drops; a child of sshd would not.
# Output goes to build.log; run-windows-test.sh polls it for "BUILD-EXIT".
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = "$here\build.log"
Remove-Item $log -ErrorAction SilentlyContinue
# Hidden: with Windows Terminal as the default terminal, every console a task
# opens becomes a Terminal window that stays after the task ends (the VM's
# default is set to the classic console host, which honours -WindowStyle).
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
  "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command " +
  "`"& '$here\build.ps1' *> '$log'`"")
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName 'KanbanCodeE2EBuild' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'KanbanCodeE2EBuild'
"build started"
