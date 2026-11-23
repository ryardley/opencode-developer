#!/usr/bin/env bash
# install-skills.sh: install the bundled opencode skills without running ralph.
#
# ralph syncs the `tk-tickets` and `podman` skills into a target repo's
# `.opencode/skills/` on every run. This script does the same install on its
# own, so you can set up a repo (or your host config) without starting a loop.
#
# Sources are resolved from the flake layout (`../share/<name>/SKILL.md`) when
# installed as a package, falling back to the repo layout
# (`../skills/<name>/SKILL.md`) when run straight from a checkout.
set -euo pipefail

SKILLS=(tk-tickets podman)

usage() {
  cat <<'EOF'
usage: install-skills.sh [--global] [--dry-run] [--no-commit] [skill...]

Install the bundled opencode skills (default: all of tk-tickets, podman).

By default they go into the current repo's `.opencode/skills/<name>/SKILL.md`
and are committed if new or changed (like ralph does). With --global they go
into ${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills/<name>/SKILL.md and are
never committed.

Options:
  --global      install into the host config instead of the current repo
  --dry-run     show what would be written, change nothing
  --no-commit   write project skills but do not git commit them
  -h, --help    show this help

Examples:
  install-skills.sh                 # all skills into this repo, committed
  install-skills.sh tk-tickets      # just one skill
  install-skills.sh --global        # host-global install
  install-skills.sh --dry-run       # preview
EOF
}

die() { echo "error: $*" >&2; exit 1; }

GLOBAL=0
DRY_RUN=0
COMMIT=1
SELECTED=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --global) GLOBAL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-commit) COMMIT=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) SELECTED+=("$1"); shift ;;
  esac
done

if (( ${#SELECTED[@]} == 0 )); then
  SELECTED=("${SKILLS[@]}")
fi
for name in "${SELECTED[@]}"; do
  found=0
  for known in "${SKILLS[@]}"; do
    [[ "$name" == "$known" ]] && found=1
  done
  (( found )) || die "unknown skill: $name (known: ${SKILLS[*]})"
done

# Resolve the skill sources: flake package layout first, then repo layout.
SELF_DIR="$(dirname "$(readlink -f "$0")")"
skill_src() {
  local name="$1" candidate
  for candidate in "$SELF_DIR/../share/$name/SKILL.md" "$SELF_DIR/skills/$name/SKILL.md"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if (( GLOBAL )); then
  DEST_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills"
  COMMIT=0
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repo; use --global for a host install"
  DEST_ROOT="$ROOT/.opencode/skills"
fi

export NO_COLOR=1

install_skill() {
  local name="$1" src dst
  src="$(skill_src "$name")" || die "bundled $name skill not found (looked in $SELF_DIR/../share and $SELF_DIR/skills)"
  dst="$DEST_ROOT/$name/SKILL.md"

  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    echo "up to date: $dst"
    return 0
  fi

  if (( DRY_RUN )); then
    echo "would install: $src -> $dst"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  # The store source is read-only; recreate with a writable mode so the
  # installed skill stays editable and idempotent overwrites succeed.
  rm -f "$dst"
  install -m 0644 "$src" "$dst"
  echo "installed: $dst"

  if (( COMMIT )); then
    # Force-add (in case `.opencode/` is gitignored) and commit only if the
    # working tree actually changed, keeping the tree clean for the ticket loop.
    git -C "$ROOT" add -f "$dst"
    if ! git -C "$ROOT" diff --cached --quiet -- "$dst"; then
      git -C "$ROOT" commit -q -m "chore: sync $name skill"
      echo "committed: chore: sync $name skill"
    fi
  fi
}

for name in "${SELECTED[@]}"; do
  install_skill "$name"
done
