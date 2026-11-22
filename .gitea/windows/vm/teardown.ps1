# Undo setup.ps1: stop the app, keep the run's data for a look afterwards,
# and put the real board data back. Safe to run more than once.
# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less files as ANSI.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$data = "$env:APPDATA\kanban-code"
$saved = "$env:APPDATA\kanban-code.e2e-saved"
$transcripts = "$env:USERPROFILE\.claude\projects\C--Users-dev-code-kc-e2e"
$keep = "$here\last-run"

& "$here\stop-app.ps1"

Remove-Item -Recurse -Force $keep -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $keep | Out-Null
if (Test-Path $saved) {
  if (Test-Path $data) { Move-Item $data "$keep\app-data" }
  Move-Item $saved $data
  "board data restored"
} else {
  "nothing set aside; board data left as it is"
}
# The run's transcripts would otherwise show up as discovered sessions.
if (Test-Path $transcripts) { Move-Item $transcripts "$keep\transcripts" }
"run data kept in $keep"
