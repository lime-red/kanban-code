# Print the Claude Code processes running under a drawer terminal, as JSON:
# [{ "pid": 123, "marker": "kanban-pty-..." }]. A drawer terminal is a
# cmd.exe started with "/k rem kanban-pty-<uuid>"; tests use this to check
# that the terminal's Claude survives tab switches and ends with the drawer.
$all = @{}
Get-CimInstance Win32_Process | ForEach-Object { $all[[int]$_.ProcessId] = $_ }
$out = @()
foreach ($p in $all.Values | Where-Object { $_.Name -eq 'claude.exe' }) {
  $cur = $p
  for ($i = 0; $i -lt 6 -and $cur; $i++) {
    $cur = $all[[int]$cur.ParentProcessId]
    if ($cur -and $cur.Name -eq 'cmd.exe' -and $cur.CommandLine -match '(kanban-pty-[0-9a-f-]+)') {
      $out += [pscustomobject]@{ pid = [int]$p.ProcessId; marker = $Matches[1] }
      break
    }
  }
}
ConvertTo-Json -Compress -InputObject @($out)
