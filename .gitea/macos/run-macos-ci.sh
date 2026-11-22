#!/usr/bin/env bash
# macOS build and test of a kanban-code branch in a throwaway Tart VM.
#
#   .gitea/macos/run-macos-ci.sh [ref]        # default ref: HEAD
#   .gitea/macos/run-macos-ci.sh fix/linux-memmem-ambiguity
#
# Runs on lime's Mac, by hand, at the desk (issue #22). The Linux runner can't
# build the SwiftUI/AppKit app or SwiftTerm; this can, with a full Xcode that
# lives in the VM instead of on the Mac.
#
# What happens:
#   1. The Xcode image is pulled into TART_HOME on the external SSD, only if it
#      isn't there already. Every later run reuses it.
#   2. A base VM is prepared from the image, once per image: it adds what the
#      tests need and the image lacks (tmux, for the real-tmux launch tests).
#      `tart clone` then makes a fresh VM from that base for each run. On APFS
#      both are copy-on-write: instant, and they take only the space they write.
#      Delete the base (`tart delete kc-ci-base-<tag>`) to rebuild it.
#   3. The ref is exported with `git archive` from this repo (fetching origin
#      first), shared into the VM read-only, and unpacked onto the VM's disk.
#      The VM needs no Git credentials.
#   4. swift build and swift test run in the VM; output streams here and is
#      saved under $LOG_DIR.
#   5. The VM is stopped and deleted, whatever happened.
#   6. The result is posted to Gitea as a commit status ("macos / build+test":
#      pending, then success, failure or error), so it shows on the commit and
#      any PR for it. The token (claude account, write:repository) is read from
#      the login Keychain; without it, or for a SWIFT_TEST_ARGS run (a partial
#      run shouldn't mark a commit green), nothing is posted. Store it with:
#        security add-generic-password -a claude -s gitea-commit-status -w
#
# Settings (environment):
#   TART_HOME   where Tart keeps images and VMs   (default: /Volumes/Build VMs/tart)
#   IMAGE       the macOS + Xcode image            (default: Xcode 26.5 on macOS 26)
#   VM_CPUS     cores for the VM                   (default: 4 of the Mac's 10)
#   VM_MEMORY   MB of RAM for the VM               (default: 8192)
#   LOG_DIR     where run logs go                  (default: $TART_HOME/../ci-logs)
#   SWIFT_TEST_ARGS  run one swift test pass with these arguments instead
#                    (e.g. "--filter ByteSearch")
#   SERIAL_TESTS     regex of suites run one test at a time after the rest
#   SKIP_TESTS       regex of tests not run in the VM (see below)
#   REPORT_STATUS    0 to not post a commit status   (default: 1)
#
# Exit status: 0 if build and tests pass, 1 if they fail, 2 for setup problems.
set -euo pipefail

export TART_HOME="${TART_HOME:-/Volumes/Build VMs/tart}"
IMAGE="${IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:26.5}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-8192}"
LOG_DIR="${LOG_DIR:-$(dirname "$TART_HOME")/ci-logs}"
SWIFT_TEST_ARGS="${SWIFT_TEST_ARGS:-}"
# Suites whose waits are tight enough (the vault broker allows 2 s per
# approval; ImageSender's waitForReady polls a fake pane for a few seconds)
# that the VM's slower, shared CPUs fail them when the whole suite runs in
# parallel. They pass reliably run one at a time, so they get a second, serial
# pass. A regex for swift test's --filter / --skip.
SERIAL_TESTS="${SERIAL_TESTS:-Vault|RemoteControlServerTests|ImagePasteTests|ImageSenderMultiAssistant}"
# Tests skipped in the VM: RemoteControlServerTests' "events pushes at most
# once per push interval" (eventsThrottle) expects a push within 1.2 s of 20
# changes made 20 ms apart, and in the VM the sleeps alone use up that window;
# it fails there every time, even run alone.
SKIP_TESTS="${SKIP_TESTS:-eventsThrottle}"
REF="${1:-HEAD}"

die() { echo "run-macos-ci: $*" >&2; exit 2; }

command -v tart >/dev/null || die "tart isn't installed (brew install openai/tools/tart)"
[ -d "$(dirname "$TART_HOME")" ] || die "$(dirname "$TART_HOME") isn't mounted; plug in the Build VMs SSD"
mkdir -p "$TART_HOME" "$LOG_DIR"

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
git -C "$repo" fetch --quiet origin || echo "run-macos-ci: fetch from origin failed; using local refs" >&2
# Prefer origin's copy of a branch name, so the run tests what was pushed.
if git -C "$repo" rev-parse --verify --quiet "origin/$REF^{commit}" >/dev/null; then
  commit=$(git -C "$repo" rev-parse "origin/$REF^{commit}")
else
  commit=$(git -C "$repo" rev-parse --verify "$REF^{commit}") || die "no such ref: $REF"
fi
short=${commit:0:9}

stamp=$(date +%Y%m%d-%H%M%S)
vm="kc-ci-$stamp"
log="$LOG_DIR/$stamp-${REF//\//_}-$short.log"
work=$(mktemp -d)

# Commit status on Gitea. The token goes to curl on stdin (-H @-), never on its
# command line, where ps would show it.
STATUS_API="https://gitea-hl.taild204f.ts.net/api/v1/repos/lime/kanban-code/statuses"
STATUS_CONTEXT="macos / build+test"
status_token=""
if [ "${REPORT_STATUS:-1}" = 1 ] && [ -z "$SWIFT_TEST_ARGS" ]; then
  status_token=$(security find-generic-password -a claude -s gitea-commit-status -w 2>/dev/null || true)
  [ -n "$status_token" ] || echo "run-macos-ci: no gitea-commit-status token in the Keychain; not posting a commit status" >&2
fi
post_status() {  # <pending|success|failure|error> <description>
  [ -n "$status_token" ] || return 0
  local body code
  body=$(STATE="$1" DESC="$2" CTX="$STATUS_CONTEXT" python3 -c \
    'import json,os; print(json.dumps({"state":os.environ["STATE"],"description":os.environ["DESC"][:140],"context":os.environ["CTX"]}))')
  code=$(printf 'Authorization: token %s\n' "$status_token" |
    curl -s -o /dev/null -w '%{http_code}' -X POST -H @- -H 'Content-Type: application/json' \
      --data "$body" "$STATUS_API/$commit") || code="curl failed"
  case "$code" in
    2??) ;;
    *) echo "run-macos-ci: posting the $1 commit status failed ($code); is $short pushed to origin?" >&2 ;;
  esac
}

cleanup() {
  status=$?
  # 0 and 1 posted their verdict below; anything else (setup failed, or
  # interrupted) mustn't leave the commit pending.
  case "$status" in
    0|1) ;;
    *) post_status error "run aborted (exit $status) before the tests finished" ;;
  esac
  if tart list --quiet 2>/dev/null | grep -qx "$vm"; then
    tart stop "$vm" >/dev/null 2>&1 || true
    tart delete "$vm" >/dev/null 2>&1 || true
  fi
  [ -n "${run_pid:-}" ] && kill "$run_pid" 2>/dev/null || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT INT TERM
post_status pending "building and testing in a Tart VM on lime's Mac"

# 1. The image: pulled once, then served from TART_HOME's OCI cache.
if ! tart list --source oci --quiet | grep -qx "$IMAGE"; then
  echo "== Pulling $IMAGE into $TART_HOME (once; about 69 GB)"
  tart pull "$IMAGE"
fi

wait_for_boot() {  # <vm> <pid of its tart run>
  echo "== Waiting for $1 to boot"
  for _ in $(seq 1 90); do
    tart exec "$1" true >/dev/null 2>&1 && return 0
    kill -0 "$2" 2>/dev/null || { cat "$work/tart-run.log" >&2; die "$1 exited while booting"; }
    sleep 2
  done
  die "$1 didn't answer tart exec within 3 minutes"
}

# 2a. The base VM: the image plus tmux, built once per image.
base="kc-ci-base-${IMAGE##*:}"
if ! tart list --source local --quiet | grep -qx "$base"; then
  echo "== Preparing $base from $IMAGE (once)"
  tart clone "$IMAGE" "$base.tmp"
  tart run "$base.tmp" --no-graphics >"$work/tart-run.log" 2>&1 &
  base_pid=$!
  wait_for_boot "$base.tmp" "$base_pid"
  # sync and a graceful stop: stopped straight after the install, the VM lost
  # it (the base came back without tmux).
  tart exec "$base.tmp" /bin/bash -lc 'HOMEBREW_NO_AUTO_UPDATE=1 brew install tmux && /opt/homebrew/bin/tmux -V && sync' \
    || { tart stop "$base.tmp"; tart delete "$base.tmp"; die "couldn't install tmux in the base VM"; }
  tart stop --timeout 120 "$base.tmp"
  wait "$base_pid" 2>/dev/null || true
  tart rename "$base.tmp" "$base"
fi

# 2b. A throwaway VM for this run.
echo "== Cloning $vm from $base"
tart clone "$base" "$vm"
tart set "$vm" --cpu "$VM_CPUS" --memory "$VM_MEMORY"

# 3. The source, as a tarball shared read-only into the VM.
git -C "$repo" archive --format=tar -o "$work/src.tar" "$commit"
tart run "$vm" --no-graphics --dir="src:$work:ro" >"$work/tart-run.log" 2>&1 &
run_pid=$!
wait_for_boot "$vm" "$run_pid"

# 4. Build and test inside the VM. Shared folders appear under
#    /Volumes/My Shared Files; building there would be slow, so unpack locally.
echo "== Testing $REF ($short) in $vm; log: $log"
set +e
tart exec "$vm" /bin/bash -lc "
  set -euo pipefail
  rm -rf ~/src && mkdir ~/src && cd ~/src
  tar -xf '/Volumes/My Shared Files/src/src.tar'
  sw_vers -productVersion | sed 's/^/macOS /'
  xcodebuild -version | head -1
  echo '== swift build --build-tests'
  swift build --build-tests
  if [ -n '$SWIFT_TEST_ARGS' ]; then
    echo '== swift test $SWIFT_TEST_ARGS'
    swift test --skip-build $SWIFT_TEST_ARGS
  else
    status=0
    echo '== swift test, in parallel, except the timing-sensitive suites'
    swift test --skip-build --skip '$SERIAL_TESTS' --skip '$SKIP_TESTS' || status=1
    echo '== swift test, one at a time: $SERIAL_TESTS'
    swift test --skip-build --no-parallel --filter '$SERIAL_TESTS' --skip '$SKIP_TESTS' || status=1
    exit \$status
  fi
" 2>&1 | tee "$log"
result=${PIPESTATUS[0]}
set -e

if [ "$result" -eq 0 ]; then
  echo "== PASS: $REF ($short)" | tee -a "$log"
  post_status success "build and tests passed on $(grep -m1 '^macOS ' "$log" || echo macOS); log ${log##*/}"
  exit 0
fi
echo "== FAIL ($result): $REF ($short). Log: $log" | tee -a "$log"
post_status failure "build or tests failed; log ${log##*/} on lime's Mac"
exit 1
