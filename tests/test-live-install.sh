#!/usr/bin/env bash
# Private-only checks for this machine's installation of the harness. The other files in this directory
# are the public harness's tests (Pgr00t/claude-ticket-harness, hooks/tests/), which run the scripts against
# throwaway repos; this one checks what is wired around them here: the hook entries in ~/.claude/settings.json
# name these scripts and the gate timeout covers every target repo's budget twice, and each target repo's
# .claude/harness.json parses and carries the site values the scripts stopped hard-coding on 2026-11-05
# (the app/queue/ deploy path, the OPENAI_API_KEY suite default, the ParasInstill gh account, the release
# branch customers run). Run: bash ~/.claude/hooks/tests/test-live-install.sh
set -u
HOOKS="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
API="$HOME/Desktop/Work/instill-app-api"
WEB="$HOME/Desktop/Work/instill-app-web-beta"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$2"; }

echo "# ~/.claude/settings.json runs these scripts"
for s in judge-gate.sh judge-status.sh format-on-edit.sh link-worktree-local-files.sh; do
  if jq -e --arg s "$s" '[.hooks[][]?.hooks[]? | select(.command | test($s))] | length > 0' "$SETTINGS" >/dev/null 2>&1 && [ -f "$HOOKS/$s" ]; then
    ok "settings.json runs $s and the script exists"
  else
    bad "settings.json runs $s and the script exists" "$(jq -c '[.hooks[][]?.hooks[]?.command]' "$SETTINGS" 2>/dev/null) $(ls "$HOOKS" 2>/dev/null | tr '\n' ' ')"
  fi
done
TIMEOUT=$(jq -r '[.hooks.PreToolUse[]?.hooks[]? | select(.command | test("judge-gate")) | .timeout] | first // empty' "$SETTINGS" 2>/dev/null)
DEFAULT_BUDGET=$(grep -Eo "cfg '.budget' [0-9]+" "$HOOKS/judge-gate.sh" | grep -Eo '[0-9]+$')
[ -n "$TIMEOUT" ] && [ -n "$DEFAULT_BUDGET" ] && ok "the gate entry has a timeout ($TIMEOUT s) and the script a default budget ($DEFAULT_BUDGET s)" || bad 'the gate entry has a timeout and the script a default budget' "timeout=$TIMEOUT budget=$DEFAULT_BUDGET"

echo "# each target repo's .claude/harness.json"
for R in "$API" "$WEB"; do
  N=$(basename "$R"); C="$R/.claude/harness.json"
  if ! jq -e . "$C" >/dev/null 2>&1; then bad "$N: harness.json is valid JSON" "$(head -c 200 "$C" 2>/dev/null)"; continue; fi
  ok "$N: harness.json is valid JSON"
  BUDGET=$(jq -r '.budget // empty' "$C"); BUDGET=${BUDGET:-$DEFAULT_BUDGET}
  [ -n "$TIMEOUT" ] && [ "$TIMEOUT" -ge $((BUDGET * 2)) ] && ok "$N: the gate timeout ($TIMEOUT s) is at least twice its budget ($BUDGET s)" || bad "$N: the gate timeout is at least twice its budget" "timeout=$TIMEOUT budget=$BUDGET"
  [ "$(jq -r '.status.gh_user // empty' "$C")" = ParasInstill ] && ok "$N: the status hook is pinned to ParasInstill (two gh accounts are signed in here)" || bad "$N: the status hook is pinned to ParasInstill" "$(jq -c .status "$C")"
  BR=$(jq -r '.outcomes.release_branch // empty' "$C")
  [ -n "$BR" ] && git -C "$R" rev-parse -q --verify "refs/remotes/origin/$BR" >/dev/null 2>&1 && ok "$N: outcomes.release_branch ($BR) exists on origin" || bad "$N: outcomes.release_branch exists on origin" "branch=$BR"
  [ "$(jq -r '.outcomes.sentry.org // empty' "$C")" = instillai ] && [ "$(jq -r '.outcomes.jira.site // empty' "$C")" = instill.atlassian.net ] && ok "$N: the outcomes pass knows the Sentry org and the Jira site" || bad "$N: the outcomes pass knows the Sentry org and the Jira site" "$(jq -c .outcomes "$C")"
  [ -z "$(git -C "$R" status --porcelain -- .claude/harness.json 2>/dev/null)" ] && ok "$N: harness.json is excluded from git" || bad "$N: harness.json is excluded from git" "$(git -C "$R" status --porcelain -- .claude/harness.json)"
done

echo "# the API values the private scripts used to hard-code"
C="$API/.claude/harness.json"
jq -e '.deploy.paths | index("app/queue/")' "$C" >/dev/null 2>&1 && ok 'api: app/queue/ is on the deploy surface' || bad 'api: app/queue/ is on the deploy surface' "$(jq -c .deploy "$C")"
jq -e '.deploy.paths | (index(".github/workflows/") != null) and (index("alembic/") != null) and (index("migrations/") != null) and (index("Makefile") != null) and (index("Dockerfile*") != null)' "$C" >/dev/null 2>&1 && ok 'api: the default deploy paths are kept beside it (deploy.paths replaces the list)' || bad 'api: the default deploy paths are kept beside it' "$(jq -c .deploy "$C")"
[ "$(jq -r '.suite.env.OPENAI_API_KEY // empty' "$C")" = sk-test-dummy ] && ok 'api: the suite gets the dummy OPENAI_API_KEY the settings tree needs' || bad 'api: the suite gets the dummy OPENAI_API_KEY' "$(jq -c .suite "$C")"
jq -e '.outcomes.sentry.projects == ["instill-app-api","instill-app-api-worker"]' "$C" >/dev/null 2>&1 && ok 'api: Sentry projects are the API and its worker' || bad 'api: Sentry projects are the API and its worker' "$(jq -c .outcomes.sentry "$C")"
jq -e '.outcomes.sentry.projects == ["instill-app-web"]' "$WEB/.claude/harness.json" >/dev/null 2>&1 && ok 'web: the Sentry project is the web app' || bad 'web: the Sentry project is the web app' "$(jq -c .outcomes.sentry "$WEB/.claude/harness.json")"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
