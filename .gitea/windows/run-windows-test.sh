#!/usr/bin/env bash
# Build a kanban-code ref on the Windows test VM and run the end-to-end checks.
#
#   .gitea/windows/run-windows-test.sh [ref]       # default ref: HEAD
#   SKIP_BUILD=1 .gitea/windows/run-windows-test.sh   # reuse the VM's last build
#   SPEC=04 .gitea/windows/run-windows-test.sh        # only specs matching "04"
#
# Run from a Mac with SSH access to the VM (by hand, or by a Claude session).
# Linux CI already runs cargo test and the frontend build; this covers what
# only a running Windows app shows: ConPTY terminals, cmd.exe process trees,
# WebView2, and how Claude Code on Windows writes its transcripts.
#
# What happens:
#   1. The VM is checked (and powered on with VM_POWER_ON, if set).
#   2. The ref goes over as a git bundle, so the VM needs no Git credentials.
#      vm/build.ps1 checks it out in the VM's clone, runs cargo test and builds
#      the release app, as a scheduled task that survives SSH drops. Its
#      output streams into the log here.
#   3. vm/setup.ps1 sets the VM's real board data aside, starts the app on
#      fresh data holding only the test project (C:\Users\dev\code\kc-e2e),
#      with WebView2 remote debugging, which is tunnelled to 127.0.0.1:9222.
#   4. e2e/run.js drives the app with Playwright through specs/ in order. The
#      specs start real Claude Code sessions (a few short prompts).
#   5. Whatever happened, vm/teardown.ps1 stops the app and restores the real
#      board data (the run's data is kept in %TEMP%\kc-e2e\last-run), and the
#      VM is powered off with VM_POWER_OFF, if set.
#
# Settings (environment):
#   VM_HOST        the VM            (default: dev@gitea-win11-hl.taild204f.ts.net)
#   VM_SSH_KEY     its SSH key       (default: ~/.ssh/claude)
#   VM_POWER_ON    command that powers the VM on   (default: none; the VM must be up)
#   VM_POWER_OFF   command that powers it off after the run (default: none)
#   LOG_DIR        run logs and screenshots (default: ~/Library/Logs/kanban-code-ci/windows)
#   SKIP_BUILD=1   test the app the VM built last, without checking out or building
#   SPEC           run only specs whose file name contains this
#   RUNTIME        card runtime to test: windows (cmd.exe, default) or wsl
#                  (Claude in a tmux session inside WSL)
#   KEEP_APP=1     leave the app running on test data afterwards (for a look);
#                  run vm/teardown.ps1 on the VM to restore the real board
#
# Exit status: 0 if everything passed, 1 if a test failed, 2 for setup problems.
set -euo pipefail

VM_HOST="${VM_HOST:-dev@gitea-win11-hl.taild204f.ts.net}"
VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/claude}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/kanban-code-ci/windows}"
VM_DIR='C:\Users\dev\AppData\Local\Temp\kc-e2e'
VM_DIR_SCP='C:/Users/dev/AppData/Local/Temp/kc-e2e'
REF="${1:-HEAD}"

here=$(cd "$(dirname "$0")" && pwd)
ssh_opts=(-i "$VM_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)

die() { echo "run-windows-test: $*" >&2; exit 2; }
vm() { ssh "${ssh_opts[@]}" "$VM_HOST" "$@" </dev/null; }
vm_ps() { vm "powershell -NoProfile -ExecutionPolicy Bypass -File $VM_DIR\\$1"; }

command -v node >/dev/null || die "node isn't installed"
repo=$(git -C "$here" rev-parse --show-toplevel)
git -C "$repo" fetch --quiet origin || echo "run-windows-test: fetch from origin failed; using local refs" >&2
if git -C "$repo" rev-parse --verify --quiet "origin/$REF^{commit}" >/dev/null; then
  commit=$(git -C "$repo" rev-parse "origin/$REF^{commit}")
else
  commit=$(git -C "$repo" rev-parse --verify "$REF^{commit}") || die "no such ref: $REF"
fi
short=${commit:0:9}

stamp=$(date +%Y%m%d-%H%M%S)
run_dir="$LOG_DIR/$stamp-${REF//\//_}-$short"
mkdir -p "$run_dir"
log="$run_dir/run.log"
exec > >(tee -a "$log") 2>&1
work=$(mktemp -d)
tunnel_pid=""
set_up=""

cleanup() {
  status=$?
  [ -n "$tunnel_pid" ] && kill "$tunnel_pid" 2>/dev/null || true
  if [ -n "$set_up" ] && [ -z "${KEEP_APP:-}" ]; then
    echo "== Teardown"
    vm_ps teardown.ps1 || echo "run-windows-test: teardown failed; run vm/teardown.ps1 on the VM" >&2
  fi
  [ -n "${VM_POWER_OFF:-}" ] && { echo "== Powering the VM off"; eval "$VM_POWER_OFF" || true; }
  rm -rf "$work"
  case $status in
    0) echo "== PASS: $REF ($short). Log: $log" ;;
    1) echo "== FAIL: $REF ($short). Log and screenshots: $run_dir" ;;
    *) echo "== ERROR ($status): $REF ($short). Log: $log" ;;
  esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 2' INT TERM

# 1. The VM.
if ! vm 'exit 0' 2>/dev/null; then
  [ -n "${VM_POWER_ON:-}" ] || die "can't reach $VM_HOST over SSH (set VM_POWER_ON to start it)"
  echo "== Powering the VM on"
  eval "$VM_POWER_ON"
  for _ in $(seq 1 60); do vm 'exit 0' 2>/dev/null && break; sleep 5; done
  vm 'exit 0' || die "$VM_HOST didn't answer SSH within 5 minutes of power-on"
fi
if lsof -nP -iTCP:9222 -sTCP:LISTEN >/dev/null 2>&1; then
  die "something on this Mac already listens on port 9222 (an old tunnel?)"
fi
vm "New-Item -ItemType Directory -Force $VM_DIR | Out-Null"
scp -q "${ssh_opts[@]}" "$here"/vm/*.ps1 "$here"/vm/*.sh "$VM_HOST:$VM_DIR_SCP/"

# 2. Build.
if [ -z "${SKIP_BUILD:-}" ]; then
  echo "== Building $REF ($short) on the VM"
  git -C "$repo" update-ref refs/e2e/run "$commit"
  git -C "$repo" bundle create --quiet "$work/src.bundle" refs/e2e/run
  git -C "$repo" update-ref -d refs/e2e/run
  echo "$commit" >"$work/commit.txt"
  scp -q "${ssh_opts[@]}" "$work/src.bundle" "$work/commit.txt" "$VM_HOST:$VM_DIR_SCP/"
  vm_ps start-build.ps1
  seen=0
  for _ in $(seq 1 180); do   # 60 minutes
    sleep 20
    out=$(vm "Get-Content $VM_DIR\\build.log -ErrorAction SilentlyContinue" 2>/dev/null | tr -d '\r') || continue
    total=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    [ "$total" -gt "$seen" ] && { printf '%s\n' "$out" | tail -n +"$((seen + 1))"; seen=$total; }
    code=$(printf '%s\n' "$out" | sed -n 's/^BUILD-EXIT \([0-9]*\).*/\1/p' | tail -1)
    if [ -n "$code" ]; then
      [ "$code" = 0 ] && break
      [ "$code" = 1 ] && { echo "run-windows-test: cargo test failed on Windows"; exit 1; }
      die "build failed (BUILD-EXIT $code)"
    fi
  done
  [ "${code:-}" = 0 ] || die "build didn't finish within 60 minutes"
else
  echo "== SKIP_BUILD: testing the app the VM built last"
fi

# 3. App on test data, and the debug-port tunnel.
echo "== Starting the app on test data"
set_up=1
vm_ps setup.ps1 || die "VM setup failed"
ssh "${ssh_opts[@]}" -o ExitOnForwardFailure=yes -N -L 9222:127.0.0.1:9222 "$VM_HOST" </dev/null &
tunnel_pid=$!
for _ in $(seq 1 15); do curl -fsS -m 3 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && break; sleep 2; done
curl -fsS -m 3 http://127.0.0.1:9222/json/version >/dev/null || die "the debug-port tunnel didn't come up"

# 4. The checks.
if [ ! -d "$here/e2e/node_modules/playwright-core" ]; then
  echo "== Installing playwright-core for the e2e runner (once)"
  npm install --prefix "$here/e2e" --no-audit --no-fund --silent
fi
RUNTIME="${RUNTIME:-windows}"
echo "== Running e2e specs${SPEC:+ matching $SPEC} on the $RUNTIME runtime"
set +e
VM_HOST="$VM_HOST" VM_SSH_KEY="$VM_SSH_KEY" VM_DIR="$VM_DIR" RUNTIME="$RUNTIME" \
  node "$here/e2e/run.js" "$run_dir/shots" "${SPEC:-}"
result=$?
set -e
[ "$result" -le 1 ] || die "the e2e runner itself failed (exit $result)"
exit "$result"
