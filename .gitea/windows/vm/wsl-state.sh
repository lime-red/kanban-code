#!/usr/bin/env bash
# Inside WSL: print the card tmux sessions and the Claude processes running
# under them, as JSON: {"sessions": ["kanban-card_..."], "claudes": [{"pid": 1, "session": "..."}]}
# With "kill <card-id> ...", end those cards' tmux sessions instead.
set -uo pipefail
if [ "${1:-}" = kill ]; then
  shift
  for id in "$@"; do tmux kill-session -t "kanban-$id" 2>/dev/null && echo "ended tmux session kanban-$id"; done
  exit 0
fi
python3 - <<'EOF'
import json, subprocess
def run(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""
sessions = [s for s in run("tmux", "ls", "-F", "#S").split() if s.startswith("kanban-")]
claudes = []
for s in sessions:
    for pane_pid in run("tmux", "list-panes", "-s", "-t", s, "-F", "#{pane_pid}").split():
        # Claude runs somewhere under the pane's shell.
        tree = run("ps", "-e", "-o", "pid=,ppid=,comm=")
        procs = [l.split(None, 2) for l in tree.splitlines() if l.strip()]
        children = {}
        for pid, ppid, comm in procs:
            children.setdefault(ppid, []).append((pid, comm))
        stack = [pane_pid]
        while stack:
            p = stack.pop()
            for pid, comm in children.get(p, []):
                if comm.startswith("claude"):
                    claudes.append({"pid": int(pid), "session": s})
                stack.append(pid)
print(json.dumps({"sessions": sessions, "claudes": claudes}))
EOF
