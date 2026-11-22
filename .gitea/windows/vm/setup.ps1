# Prepare the VM for an end-to-end run and start the app.
#
#   - Sets the real board data (%APPDATA%\kanban-code) aside as
#     kanban-code.e2e-saved; teardown.ps1 puts it back. The run starts from a
#     fresh data folder holding only a copy of settings.json, whose project list
#     is replaced by the test project, so tests never see or change real cards.
#   - Makes the test project (C:\Users\dev\code\kc-e2e, a small git repo),
#     marks it trusted in ~\.claude.json so Claude Code skips the folder trust
#     prompt, and deletes its old transcripts.
#   - Starts the release build in dev's desktop session (a scheduled task: an
#     SSH child has no desktop) with WebView2 remote debugging on 9222.
#
# Exit status: 0 ready, 2 setup failed.
# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less files as ANSI.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')
$data = "$env:APPDATA\kanban-code"
$saved = "$env:APPDATA\kanban-code.e2e-saved"
$project = "$env:USERPROFILE\code\kc-e2e"
$transcripts = "$env:USERPROFILE\.claude\projects\C--Users-dev-code-kc-e2e"
$exe = "$env:USERPROFILE\code\kanban-code\windows\src-tauri\target\release\kanban-code.exe"
if (-not (Test-Path $exe)) { "missing $exe"; exit 2 }

& "$here\stop-app.ps1"

if (Test-Path $saved) {
  # A previous run ended without teardown. Its data folder is test data.
  "previous run was not torn down; restoring the saved board first"
  & "$here\teardown.ps1"
}
if (Test-Path $data) {
  Move-Item $data $saved
  "board data set aside in $saved"
}
New-Item -ItemType Directory -Force $data | Out-Null

# JSON edits go through node: PowerShell 5.1's ConvertTo-Json reshapes
# arrays and writes a BOM, which the app's settings reader rejects.
$js = "$here\json-edit.js"
@'
const fs = require('fs');
const [mode, src, dst, project] = process.argv.slice(2);
const read = (f) => {
  const raw = fs.readFileSync(f, 'utf8');
  return JSON.parse(raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw);
};
if (mode === 'settings') {
  const s = fs.existsSync(src) ? read(src) : {};
  s.hasCompletedOnboarding = true;
  s.projects = [{ path: project, name: 'kc-e2e' }];
  fs.writeFileSync(dst, JSON.stringify(s, null, 2));
} else if (mode === 'trust') {
  const j = read(src);
  const key = project.replace(/\\/g, '/');
  j.projects = j.projects || {};
  j.projects[key] = Object.assign({}, j.projects[key], { hasTrustDialogAccepted: true });
  fs.writeFileSync(src, JSON.stringify(j, null, 2));
}
'@ | Set-Content -Encoding ASCII $js
node $js settings "$saved\settings.json" "$data\settings.json" $project
if ($LASTEXITCODE -ne 0) { "could not write test settings"; exit 2 }

if (-not (Test-Path "$project\.git")) {
  New-Item -ItemType Directory -Force $project | Out-Null
  git -C $project init -q -b main
  git -C $project config user.name 'Kanban E2E'
  git -C $project config user.email 'e2e@example.invalid'
  "# kanban-code e2e project`n" | Set-Content -Encoding ASCII "$project\README.md"
  git -C $project add README.md
  git -C $project commit -q -m init
}
# "-" fills the unused argument: PowerShell 5.1 drops "" when calling a program.
node $js trust "$env:USERPROFILE\.claude.json" - $project
if ($LASTEXITCODE -ne 0) { "could not mark $project trusted in .claude.json"; exit 2 }
"trusted for Claude Code: $project"
Remove-Item -Recurse -Force $transcripts -ErrorAction SilentlyContinue

$cmd = "$here\launch.cmd"
@"
@echo off
set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222 --remote-allow-origins=*
start "" "$exe"
"@ | Set-Content -Encoding ASCII $cmd
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$cmd`""
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'KanbanCodeE2ELaunch' -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'KanbanCodeE2ELaunch'

# WebView2 takes a while to come up on the VM.
for ($i = 0; $i -lt 45; $i++) {
  Start-Sleep 2
  try {
    Invoke-WebRequest -UseBasicParsing http://127.0.0.1:9222/json/list -TimeoutSec 3 | Out-Null
    "app up (pid $((Get-Process kanban-code -ErrorAction SilentlyContinue | Select-Object -First 1).Id)), debug port answering"
    exit 0
  } catch { }
}
"the app's debug port did not answer within 90 s"
exit 2
