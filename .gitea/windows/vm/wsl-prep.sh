#!/usr/bin/env bash
# Inside WSL, before a RUNTIME=wsl run: mark the test project trusted in
# Claude Code's ~/.claude.json and remove its old transcripts.
#   wsl-prep.sh /mnt/c/Users/dev/code/kc-e2e
set -euo pipefail
project="$1"
python3 - "$project" <<'EOF'
import json, os, sys
project = sys.argv[1]
path = os.path.expanduser("~/.claude.json")
data = json.load(open(path)) if os.path.exists(path) else {}
data.setdefault("projects", {}).setdefault(project, {})["hasTrustDialogAccepted"] = True
json.dump(data, open(path, "w"), indent=2)
print(f"trusted for Claude Code in WSL: {project}")
EOF
encoded=$(printf '%s' "$project" | sed 's/[^A-Za-z0-9]/-/g')
rm -rf "$HOME/.claude/projects/$encoded"
command -v tmux >/dev/null && tmux -V
command -v claude >/dev/null && claude --version
