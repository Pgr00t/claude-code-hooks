#!/usr/bin/env bash
# Tests for ~/.claude/hooks/link-worktree-local-files.sh. Run: bash ~/.claude/hooks/tests/test-link-worktree.sh
set -u
HOOK="$HOME/.claude/hooks/link-worktree-local-files.sh"
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

run_hook() { CLAUDE_PROJECT_DIR="$1" bash "$HOOK" </dev/null 2>&1; }

MAIN="$TMP/main"
git init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$MAIN/.claude/judge" "$MAIN/.venv" "$MAIN/docs/agents"
echo log > "$MAIN/.claude/loop-results.md"
echo x > "$MAIN/.claude/.hidden"
echo c > "$MAIN/CLAUDE.md"
touch "$MAIN/pyproject.toml"

# 1. A worktree under main/.claude/worktrees (the app's layout): real .claude, per-entry links, no cycle.
NESTED="$MAIN/.claude/worktrees/wt1"
git -C "$MAIN" worktree add -q --detach "$NESTED"
OUT=$(run_hook "$NESTED")
check "nested: .claude is a real directory" '[ -d "$NESTED/.claude" ] && [ ! -L "$NESTED/.claude" ]'
check "nested: loop-results.md is linked to main" '[ "$(readlink "$NESTED/.claude/loop-results.md")" = "$MAIN/.claude/loop-results.md" ]'
check "nested: dotfile entry is linked" '[ -L "$NESTED/.claude/.hidden" ]'
check "nested: judge/ is linked" '[ -L "$NESTED/.claude/judge" ]'
check "nested: no worktrees entry, so no cycle" '[ ! -e "$NESTED/.claude/worktrees" ] && [ ! -L "$NESTED/.claude/worktrees" ]'
check "nested: a recursive walk from main terminates" 'find -L "$MAIN" -maxdepth 12 -print >/dev/null 2>&1 && ! find -L "$MAIN" -maxdepth 12 2>&1 | grep -q "Too many levels"'
check "nested: CLAUDE.md linked" '[ -L "$NESTED/CLAUDE.md" ]'
check "nested: .venv linked to main/.venv" '[ "$(readlink "$NESTED/.venv")" = "$MAIN/.venv" ]'
check "nested: message reports the link" 'printf %s "$OUT" | grep -q "linked"'
check "nested: no junk line in info/exclude" '! grep -q "entries)\|replaced the cyclic" "$MAIN/.git/info/exclude"'

# 2. Idempotent: a second run changes nothing and prints nothing.
OUT2=$(run_hook "$NESTED")
check "nested: second run is silent" '[ -z "$OUT2" ]'

# 3. A new entry in main shows up on the next run.
echo n > "$MAIN/.claude/new-note.md"
run_hook "$NESTED" >/dev/null
check "nested: later main entry is topped up" '[ -L "$NESTED/.claude/new-note.md" ]'

# 4. A cyclic link left by the old hook is replaced, and main's .claude is untouched.
OLD="$MAIN/.claude/worktrees/wt2"
git -C "$MAIN" worktree add -q --detach "$OLD"
ln -s "$MAIN/.claude" "$OLD/.claude"
run_hook "$OLD" >/dev/null
check "old link: replaced by a real directory" '[ -d "$OLD/.claude" ] && [ ! -L "$OLD/.claude" ]'
check "old link: main/.claude still has its files" '[ -f "$MAIN/.claude/loop-results.md" ] && [ -d "$MAIN/.claude/judge" ]'
check "old link: no cycle" '[ ! -e "$OLD/.claude/worktrees" ]'

# 5. A real .claude (the app's copy) keeps its own files and only gains what it lacks.
APP="$MAIN/.claude/worktrees/wt3"
git -C "$MAIN" worktree add -q --detach "$APP"
mkdir -p "$APP/.claude"; echo mine > "$APP/.claude/loop-results.md"
run_hook "$APP" >/dev/null
check "app copy: own file kept" '[ ! -L "$APP/.claude/loop-results.md" ] && [ "$(cat "$APP/.claude/loop-results.md")" = mine ]'
check "app copy: missing entry added" '[ -L "$APP/.claude/judge" ]'

# 6. A worktree outside main/.claude has no cycle, so it keeps the single link.
OUTSIDE="$TMP/elsewhere"
git -C "$MAIN" worktree add -q --detach "$OUTSIDE"
run_hook "$OUTSIDE" >/dev/null
check "outside: .claude is one link to main" '[ "$(readlink "$OUTSIDE/.claude")" = "$MAIN/.claude" ]'

# 7. No venv anywhere: the message says what to run once.
rm -rf "$MAIN/.venv"
NOVENV="$MAIN/.claude/worktrees/wt4"
git -C "$MAIN" worktree add -q --detach "$NOVENV"
OUT7=$(PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" run_hook "$NOVENV")
check "no venv: message gives the one-time command" 'printf %s "$OUT7" | grep -q "poetry env use"'

# 7b. A .venv link left by an older run, pointing at a stale venv, is repointed to main's.
mkdir -p "$MAIN/.venv" "$TMP/oldvenv"
STALEWT="$MAIN/.claude/worktrees/wt5"
git -C "$MAIN" worktree add -q --detach "$STALEWT"
ln -s "$TMP/oldvenv" "$STALEWT/.venv"
run_hook "$STALEWT" >/dev/null
check "stale .venv link: repointed to main's venv" '[ "$(readlink "$STALEWT/.venv")" = "$MAIN/.venv" ]'
rm -rf "$MAIN/.venv"

# 8. The main checkout itself is left alone.
BEFORE=$(ls -A "$MAIN/.claude" | sort | tr '\n' ' ')
run_hook "$MAIN" >/dev/null
check "main checkout: untouched" '[ "$(ls -A "$MAIN/.claude" | sort | tr "\n" " ")" = "$BEFORE" ]'

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
