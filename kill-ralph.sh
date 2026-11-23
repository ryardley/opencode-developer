#!/usr/bin/env bash
# kill-ralph.sh: stop a running ralph loop and the opencode runs it spawned.
#
# ralph runs `opencode run` (via `timeout`) for each implement/verify attempt.
# Killing only the ralph process would leave those children running, so this
# walks the process tree and terminates ralph plus every descendant, then
# escalates to SIGKILL for anything that ignores SIGTERM.
#
# Run inside the devenv shell (needs pgrep/ps on PATH).
set -euo pipefail

usage() {
  cat <<'EOF'
usage: kill-ralph.sh [--dry-run] [--force]

Stop a running ralph loop and its opencode children.

  --dry-run   list the processes that would be killed, then exit
  --force     send SIGKILL immediately instead of SIGTERM first
  -h, --help  show this help

Env:
  KILL_RALPH_GRACE  seconds to wait after SIGTERM before SIGKILL (default 10)
EOF
}

die() { echo "error: $*" >&2; exit 1; }

DRY_RUN=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force|-9) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) die "unexpected argument: $1 (see --help)" ;;
  esac
done

GRACE="${KILL_RALPH_GRACE:-10}"
if ! [[ "$GRACE" =~ ^[0-9]+$ ]]; then
  die "KILL_RALPH_GRACE must be a non-negative integer"
fi

for tool in pgrep ps; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found on PATH: $tool"
done

# Match the ralph wrapper/script (installed as `ralph` or `.ralph-wrapped`,
# or run directly as `ralph.sh`) and any opencode run tagged with ralph's
# `--title ralph: ...`. `kill-ralph` itself does not match.
PATTERN='(^|/)(\.?ralph(\.sh|-wrapped)?)([[:space:]]|$)|--title ralph:'

self=$$
roots=()
while IFS= read -r pid; do
  if [[ -n "$pid" && "$pid" != "$self" ]]; then
    roots+=("$pid")
  fi
done < <(pgrep -f "$PATTERN" 2>/dev/null || true)

if (( ${#roots[@]} == 0 )); then
  echo "No running ralph process found."
  exit 0
fi

# Collect each root and all of its descendants, children first.
declare -A seen=()
tree=()
collect() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    collect "$child"
  done
  if [[ -z "${seen[$pid]:-}" ]]; then
    seen[$pid]=1
    tree+=("$pid")
  fi
}
for pid in "${roots[@]}"; do
  collect "$pid"
done

echo "Found ${#roots[@]} ralph process(es); ${#tree[@]} process(es) in total:"
for pid in "${tree[@]}"; do
  ps -o pid=,ppid=,etime=,args= -p "$pid" 2>/dev/null || true
done

if (( DRY_RUN )); then
  echo "(dry-run) would terminate the above"
  exit 0
fi

if (( FORCE )); then
  echo "Sending SIGKILL..."
  kill -KILL "${tree[@]}" 2>/dev/null || true
  echo "Killed ${#tree[@]} process(es)."
  exit 0
fi

echo "Sending SIGTERM..."
kill -TERM "${tree[@]}" 2>/dev/null || true

# Wait for the tree to exit, then SIGKILL any survivors.
deadline=$((SECONDS + GRACE))
while (( SECONDS < deadline )); do
  alive=()
  for pid in "${tree[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      alive+=("$pid")
    fi
  done
  if (( ${#alive[@]} == 0 )); then
    break
  fi
  sleep 1
done

alive=()
for pid in "${tree[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    alive+=("$pid")
  fi
done
if (( ${#alive[@]} > 0 )); then
  echo "SIGTERM ignored by ${#alive[@]} process(es); sending SIGKILL..."
  kill -KILL "${alive[@]}" 2>/dev/null || true
fi

echo "Stopped ralph."
