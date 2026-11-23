#!/usr/bin/env bash
# archive.sh: delete closed tk tickets.
#
# tk tickets are git-native markdown files in .tickets/. Closed tickets
# (status: closed) are removed from the tree with `git rm` and committed, so
# they stop showing up in `tk closed` / `tk show` while git history keeps them.
#
# Run inside the devenv shell (needs `git` on PATH).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

usage() {
  cat <<'EOF'
usage: archive.sh [--dry-run]

Delete closed tk tickets. For each ticket in .tickets/ whose frontmatter has
`status: closed`, `git rm` the file and commit the removal.

Env:
  ARCHIVE_COMMIT_MESSAGE  commit message (default "chore: archive closed tickets")

Logs: .ralph/archive-<timestamp>.log
EOF
}

die() { echo "error: $*" >&2; exit 1; }

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) die "unexpected argument: $1 (see --help)" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "required tool not found on PATH: git"

export NO_COLOR=1

LOGDIR="$ROOT/.ralph"
mkdir -p "$LOGDIR"
RUNLOG="$LOGDIR/archive-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$RUNLOG") 2>&1

if (( ! DRY_RUN )); then
  # Ignore the .ralph/ log dir itself so it never trips the clean-tree check.
  dirty=$(git status --porcelain | grep -v '^?? .ralph/' || true)
  if [[ -n "$dirty" ]]; then
    echo "error: working tree is dirty; commit or stash changes first" >&2
    echo "$dirty" >&2
    exit 1
  fi
fi

TICKETS_DIR="$ROOT/.tickets"
if [[ ! -d "$TICKETS_DIR" ]]; then
  echo "No .tickets/ directory; nothing to archive."
  exit 0
fi

# Collect closed tickets by reading the `status:` field of each frontmatter.
closed=()
while IFS= read -r -d '' f; do
  status=$(awk 'NR==1 && $0=="---" {fm=1; next}
                fm && $0=="---" {exit}
                fm && $0 ~ /^status:/ {sub(/^status:[[:space:]]*/, ""); print; exit}' "$f")
  if [[ "$status" == "closed" ]]; then
    closed+=("$f")
  fi
done < <(find "$TICKETS_DIR" -maxdepth 1 -name '*.md' -print0)

if (( ${#closed[@]} == 0 )); then
  echo "No closed tickets to archive."
  exit 0
fi

echo "Archiving ${#closed[@]} closed ticket(s):"
for f in "${closed[@]}"; do
  echo "  $(basename "$f")"
done

if (( DRY_RUN )); then
  echo "(dry-run) would: git rm the above and commit"
  exit 0
fi

git rm -q "${closed[@]}"
git commit -q -m "${ARCHIVE_COMMIT_MESSAGE:-chore: archive closed tickets}"
echo "Archived ${#closed[@]} closed ticket(s)."
