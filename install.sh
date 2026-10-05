#!/usr/bin/env bash
# Links every skill of this repository (a directory holding a SKILL.md) into
# ~/.claude/skills/<name>, <name> being the `name:` of its front matter.
# Existing links are updated; a real directory with the same name is left alone.
#
# Usage: ./install.sh [--dry-run]
# Env: CLAUDE_SKILLS_DIR (default ~/.claude/skills)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

run() { if [ "$DRY" = 1 ]; then echo "would: $*"; else "$@"; fi; }

[ "$DRY" = 1 ] || mkdir -p "$DEST"
find "$ROOT" -mindepth 3 -maxdepth 3 -name SKILL.md -not -path '*/.git/*' | sort | while read -r skill; do
  dir="$(dirname "$skill")"
  name="$(sed -n '2,/^---$/s/^name:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$skill" | head -1)"
  if [ -z "$name" ]; then echo "skipped ${dir#"$ROOT"/}: no name in its front matter"; continue; fi
  target="$DEST/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "skipped $name: $target exists and isn't a link"
    continue
  fi
  run ln -sfn "$dir" "$target"
  echo "linked  $name -> ${dir#"$ROOT"/}"
done
