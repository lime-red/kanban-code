# Run wsl-state.sh inside WSL (see that script). Arguments pass through.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sh = '/mnt/' + $here.Substring(0, 1).ToLower() + ($here.Substring(2) -replace '\\', '/') + '/wsl-state.sh'
& wsl.exe -- bash $sh @args
