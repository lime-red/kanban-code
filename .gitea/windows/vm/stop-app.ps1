# Stop the app, its WebView2 browser and any drawer terminal trees it left.
# Drawer terminals start as "cmd.exe /k rem kanban-pty-<uuid>"; killing that
# tree ends the Claude Code it hosts too.
Get-Process kanban-code -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
  Where-Object { $_.CommandLine -match 'kanban-code' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='cmd.exe' AND CommandLine LIKE '%kanban-pty-%'" |
  ForEach-Object { taskkill.exe /PID $_.ProcessId /T /F 2>&1 | Out-Null }
Start-Sleep 2
