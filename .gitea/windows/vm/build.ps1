# Build and unit-test one commit of kanban-code on the Windows test VM.
# Started by run-windows-test.sh as a scheduled task (so it survives an SSH
# drop), with its output going to build.log next to this script.
#
# Inputs, in this script's folder (%TEMP%\kc-e2e):
#   src.bundle   git bundle holding refs/e2e/run
#   commit.txt   the commit to build
# The last line of output is "BUILD-EXIT <code>": 0 built and passed,
# 1 cargo test failed, 2 checkout failed, 3 build failed.
#
# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less files as ANSI.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = "$env:USERPROFILE\code\kanban-code"
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:USERPROFILE\.cargo\bin"

function Finish($code) { "BUILD-EXIT $code"; exit $code }

$commit = (Get-Content "$here\commit.txt" -Raw).Trim()
Get-Process kanban-code -ErrorAction SilentlyContinue | Stop-Process -Force

"== checkout $commit"
Set-Location $repo
git fetch -q "$here\src.bundle" "+refs/e2e/run:refs/e2e/run" 2>&1 | ForEach-Object { "$_" }
# Tracked changes and untracked files go; ignored ones (node_modules, target)
# stay, so builds after the first are incremental.
git reset -q --hard 2>&1 | ForEach-Object { "$_" }
git clean -q -fd 2>&1 | ForEach-Object { "$_" }
git checkout -q --detach $commit 2>&1 | ForEach-Object { "$_" }
if ((git rev-parse HEAD) -ne $commit) { "checkout failed"; Finish 2 }
git log --oneline -1

"== npm install"
Set-Location "$repo\windows"
npm install --no-audit --no-fund 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 3

"== cargo test --lib"
Set-Location "$repo\windows\src-tauri"
$tests = cargo test --lib 2>&1 | ForEach-Object { "$_" }
$testExit = $LASTEXITCODE
$tests | Select-String -Pattern '^test result|FAILED|panicked|^error' | ForEach-Object { $_.Line }
if ($testExit -ne 0) { $tests | Select-Object -Last 40; Finish 1 }

"== tauri build (no installer)"
Set-Location "$repo\windows"
$t = Get-Date
$build = npm run tauri build -- --no-bundle 2>&1 | ForEach-Object { "$_" }
$buildExit = $LASTEXITCODE
$build | Select-String -Pattern 'error|warning: unused|Finished|failed' | ForEach-Object { $_.Line } | Select-Object -Last 15
"build minutes: $([math]::Round(((Get-Date) - $t).TotalMinutes, 1))"
if ($buildExit -ne 0) { $build | Select-Object -Last 40; Finish 3 }
Finish 0
