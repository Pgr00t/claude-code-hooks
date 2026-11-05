#!/usr/bin/env bash
# SessionStart hook: when the session's cwd is a git worktree, symlink the
# main checkout's local-only (untracked / gitignored) files into it so the
# harness (CLAUDE.md, .claude/, env files, deps) is present. Idempotent.
# Only links what the main checkout actually has; never overwrites.
set -u

INPUT=$(cat 2>/dev/null || true)
DIR="${CLAUDE_PROJECT_DIR:-}"
[ -z "$DIR" ] && DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$DIR" ] && DIR=$(pwd)
cd "$DIR" 2>/dev/null || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
GIT_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null)
COMMON=$(git rev-parse --git-common-dir 2>/dev/null)
case "$COMMON" in /*) ;; *) COMMON="$DIR/$COMMON" ;; esac
COMMON=$(cd "$COMMON" 2>/dev/null && pwd -P)
# Not a linked worktree when git-dir and common-dir are the same place.
[ "$GIT_DIR" = "$COMMON" ] && exit 0

MAIN=$(dirname "$COMMON")
WT=$(pwd -P)
[ "$MAIN" = "$WT" ] && exit 0


# Direct dependencies whose installed version (node_modules/.package-lock.json) differs
# from package-lock.json. Empty output means node_modules matches this branch's lockfile.
stale_node_modules() {
  [ -f package-lock.json ] || return 0
  [ -f node_modules/.package-lock.json ] || { echo "node_modules missing or not installed by npm"; return 0; }
  local q='.packages | to_entries[] | select(.key | test("^node_modules/(@[^/]+/)?[^/]+$")) | select(.value.optional != true) | "\(.key) \(.value.version)"'
  diff <(jq -r "$q" package-lock.json | sort) <(jq -r "$q" node_modules/.package-lock.json | sort) | grep -E '^[<>]' | sed 's/^</wanted:/;s/^>/installed:/' | head -8
}

linked=()
notes=()  # shown in the message, never written to info/exclude
link_one() {  # $1 = relative path
  local rel="$1" src="$MAIN/$1" dst="$WT/$1"
  [ -e "$src" ] || return 0
  [ -e "$dst" ] || [ -L "$dst" ] && return 0
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst" && linked+=("$rel")
}

for f in CLAUDE.md docs/agents TODOS.md .env .env.test node_modules; do
  link_one "$f"
done

# .claude: a worktree the app made lives inside $MAIN/.claude/worktrees, so a whole-directory
# link $WT/.claude -> $MAIN/.claude is a cycle ($MAIN/.claude/worktrees/<name>/.claude/worktrees/
# <name>/.claude/...) that black, isort and find walk until "File name too long" (seen 2026-11-03).
# For those, .claude is a real directory holding one link per entry of the main one, minus
# worktrees/; a link left by an older run of this hook is replaced, a real directory (the app's
# copy) only gets the entries it lacks. A worktree elsewhere keeps the single link.
case "$WT" in
  "$MAIN"/.claude/*)
    if [ -L "$WT/.claude" ]; then
      rm -f "$WT/.claude"
      notes+=(".claude (replaced the cyclic link)")
    fi
    if [ -d "$MAIN/.claude" ]; then
      mkdir -p "$WT/.claude"
      added=0
      for src in "$MAIN"/.claude/* "$MAIN"/.claude/.[!.]*; do
        [ -e "$src" ] || [ -L "$src" ] || continue
        name=$(basename "$src")
        [ "$name" = worktrees ] && continue
        [ -e "$WT/.claude/$name" ] || [ -L "$WT/.claude/$name" ] && continue
        ln -s "$src" "$WT/.claude/$name" && added=$((added + 1))
      done
      [ "$added" -eq 0 ] || notes+=(".claude/ ($added entries)")
    fi
    ;;
  *) link_one .claude ;;
esac

# Python: reuse the main checkout's poetry venv instead of re-installing. A .venv link this
# hook made earlier is repointed when main's venv has moved on (the 3.10 -> 3.11 upgrade);
# a real .venv directory is left alone.
if [ -f "$MAIN/pyproject.toml" ] && { [ ! -e "$WT/.venv" ] || [ -L "$WT/.venv" ]; }; then
  VENV=""
  if [ -d "$MAIN/.venv" ]; then
    VENV="$MAIN/.venv"
  else
    # poetry lives behind the asdf shim, which the app's hook environment may not have on PATH.
    VENV=$(cd "$MAIN" && PATH="$HOME/.asdf/shims:$PATH" poetry env info --path 2>/dev/null || true)
  fi
  if [ -n "$VENV" ] && [ -d "$VENV" ]; then
    if [ "$(readlink "$WT/.venv" 2>/dev/null || true)" != "$VENV" ]; then
      rm -f "$WT/.venv"
      ln -s "$VENV" "$WT/.venv" && linked+=(".venv")
    fi
    EXCL="$COMMON/info/exclude"
    grep -qx '.venv' "$EXCL" 2>/dev/null || { mkdir -p "$(dirname "$EXCL")"; echo '.venv' >> "$EXCL"; }
  elif [ ! -e "$WT/.venv" ]; then
    NO_VENV=1
  fi
fi

# A symlink is not a directory to git, so "dir/" ignore patterns miss it.
# Add a bare-path exclude for anything linked that git does not already ignore.
EXCL="$COMMON/info/exclude"
for rel in "${linked[@]:-}"; do
  [ -n "$rel" ] || continue
  if ! git check-ignore -q -- "$rel" 2>/dev/null; then
    mkdir -p "$(dirname "$EXCL")"
    grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
  fi
done

STALE=$(stale_node_modules 2>/dev/null || true)
if [ ${#linked[@]} -gt 0 ] || [ ${#notes[@]} -gt 0 ] || [ -n "$STALE" ] || [ -n "${NO_VENV:-}" ]; then
  msg="Worktree of $MAIN: linked ${linked[*]:-} ${notes[*]:-} from the main checkout."
  [ -z "${NO_VENV:-}" ] || msg="$msg No venv found to link (main has no .venv and 'poetry env info' gave none): run 'poetry env use ~/.asdf/installs/python/3.11.1/bin/python && poetry install' once here."
  [ -z "$STALE" ] || msg="$msg WARNING: node_modules does not match this branch's package-lock.json (it was installed for another branch). Tests and tsc will give false results until 'npm ci' runs in the main checkout on this lockfile:"$'\n'"$STALE"
  jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m},systemMessage:$m}'
fi
exit 0
