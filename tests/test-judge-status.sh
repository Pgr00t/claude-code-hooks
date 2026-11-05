#!/usr/bin/env bash
# Tests for ~/.claude/hooks/judge-status.sh: the push recognition, the success detection from the push output,
# the target-repo rules, the branch filter, the verdict-section lookup and the status call. Everything runs
# against throwaway git repos under a temp dir with a fake `gh` first on PATH that records its arguments, so
# nothing reaches GitHub. Nothing outside the temp dir is touched (the log goes to the temp dir too).
#
#   bash ~/.claude/hooks/tests/test-judge-status.sh            # exit 0 when every case passes
#   HOOK=/path/to/judge-status.sh bash .../test-judge-status.sh
set -u
HOOK="${HOOK:-$HOME/.claude/hooks/judge-status.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/judge-status-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# --- fakes -------------------------------------------------------------------------------------
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'X'
#!/usr/bin/env bash
# Stands in for gh: `gh auth token --user X` prints a token; everything else is recorded with the token in use.
if [ "$1" = auth ] && [ "$2" = token ]; then echo "fake-token-for-$4"; exit 0; fi
{ printf 'ARGS %s\n' "$*"; printf 'GH_TOKEN %s\n' "${GH_TOKEN:-unset}"; } >> "$FAKE_GH_ARGS"
echo '{"id":1}'
X
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"
export FAKE_GH_ARGS="$T/gh.args" JUDGE_STATUS_LOG="$T/judge-status.log"

# --- fixture repos -----------------------------------------------------------------------------
gitq() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
new_repo() { # $1 = path, $2 = origin url; a repo on feature branch IT-1-thing with one commit past main
  local R="$1"; mkdir -p "$R"
  git -C "$R" init -q -b main 2>/dev/null || { gitq "$R" init; gitq "$R" checkout -b main; }
  gitq "$R" config user.email t@t.t; gitq "$R" config user.name t; gitq "$R" config commit.gpgsign false
  printf '.claude/\n' >> "$R/.git/info/exclude"
  mkdir -p "$R/.claude/judge"
  printf 'x = 0\n' > "$R/a.py"; gitq "$R" add -A; gitq "$R" commit -qm 'main'
  gitq "$R" remote add origin "$2"
  gitq "$R" checkout -qb IT-1-thing
  printf 'x = 1\n' > "$R/a.py"; gitq "$R" add -A; gitq "$R" commit -qm 'IT-1: Build thing'
}
head_sha() { git -C "$1" rev-parse HEAD; }
verdict() { # $1 = repo, $2 = sha, $3 = PASS|FAIL, $4 = utc stamp; appends one dated section like the gate does
  local V="$1/.claude/judge/IT-1-thing.verdict.md"
  [ -s "$V" ] && printf '\n' >> "$V"
  printf '# Judge verdict for IT-1-thing at %s (%s)\nUsage: input=1 output=1\n\n1. CLAUDE.md PASS\nVERDICT: %s\n' "$2" "$4" "$3" >> "$V"
}
PUSHED=' * [new branch]      IT-1-thing -> IT-1-thing'
UPDATED='   1a2b3c4..5d6e7f8  IT-1-thing -> IT-1-thing'
REJECTED=$' ! [rejected]        IT-1-thing -> IT-1-thing (fetch first)\nerror: failed to push some refs to '"'"'github.com:Acme/widgets.git'"'"

# --- runner and assertions ---------------------------------------------------------------------
OUT=""; PASS=0; FAIL=0
run_hook() { # $1 = command text, $2 = cwd, $3 = stdout the Bash tool returned, $4 = interrupted (default false)
  : > "$FAKE_GH_ARGS"
  OUT=$(jq -cn --arg c "$1" --arg d "$2" --arg o "$3" --argjson i "${4:-false}" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d,tool_response:{stdout:$o,stderr:"",interrupted:$i}}' \
    | bash "$HOOK" 2>"$T/stderr"); RC=$?
}
ok() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$(printf '%s' "$OUT" | head -c 400)"; }
expect_quiet() { # the hook never blocks: {} on stdout, exit 0
  [ "$OUT" = "{}" ] && [ "$RC" -eq 0 ] && ok "$1: prints {} and exits 0" || { OUT="stdout=$OUT rc=$RC"; bad "$1: prints {} and exits 0"; }
}
expect_nothing() { expect_quiet "$1"; [ ! -s "$FAKE_GH_ARGS" ] && ok "$1: no status posted" || { OUT="$(cat "$FAKE_GH_ARGS")"; bad "$1: no status posted"; }; }
expect_posted() { # $1 = name, $2 = owner/repo, $3 = sha, $4 = state, $5 = description
  expect_quiet "$1"
  if grep -q -- "^ARGS api -X POST repos/$2/statuses/$3 -f state=$4 -f context=judge-gate/verdict -f description=$5\$" "$FAKE_GH_ARGS"; then
    ok "$1: posts $4 to $2@${3:0:8}"
  else OUT="$(cat "$FAKE_GH_ARGS" 2>&1)"; bad "$1: posts $4 to $2@${3:0:8} with description '$5'"; fi
  grep -q '^GH_TOKEN fake-token-for-ParasInstill$' "$FAKE_GH_ARGS" && ok "$1: the call is pinned to the ParasInstill token" || { OUT="$(cat "$FAKE_GH_ARGS")"; bad "$1: the call is pinned to the ParasInstill token"; }
  [ "$(grep -c '^ARGS' "$FAKE_GH_ARGS")" = 1 ] && ok "$1: exactly one status call" || { OUT="$(cat "$FAKE_GH_ARGS")"; bad "$1: exactly one status call"; }
}

# ===============================================================================================
echo "# a gated push: the PASS section for the pushed sha becomes a success status"
R="$T/pass"; new_repo "$R" git@github.com:Acme/widgets.git; SHA=$(head_sha "$R")
verdict "$R" "$SHA" PASS 2026-11-03T10:00:00Z
run_hook 'git push -u origin IT-1-thing' "$R" "$PUSHED"
expect_posted 'new-branch push with a PASS section' Acme/widgets "$SHA" success 'VERDICT: PASS 2026-11-03T10:00:00Z'
grep -q "posted success repos/Acme/widgets/statuses/$SHA branch=IT-1-thing" "$JUDGE_STATUS_LOG" && ok 'the post is logged' || { OUT="$(cat "$JUDGE_STATUS_LOG")"; bad 'the post is logged'; }
run_hook 'git push 2>&1 | tail -8; echo "push exit: ${pipestatus[1]}"' "$R" "$UPDATED"
expect_posted 'an update push piped through tail' Acme/widgets "$SHA" success 'VERDICT: PASS 2026-11-03T10:00:00Z'
run_hook 'git push' "$R" 'Everything up-to-date'
expect_posted 'an up-to-date push still publishes the verdict' Acme/widgets "$SHA" success 'VERDICT: PASS 2026-11-03T10:00:00Z'

echo "# a FAIL then a PASS for the same sha: the PASS wins; a PASS followed by a FAIL for this sha does not count"
R="$T/failpass"; new_repo "$R" git@github.com:Acme/widgets.git; SHA=$(head_sha "$R")
verdict "$R" "$SHA" FAIL 2026-11-03T09:00:00Z; verdict "$R" "$SHA" PASS 2026-11-03T09:30:00Z
run_hook 'git push' "$R" "$PUSHED"; expect_posted 'FAIL then PASS sections for the sha' Acme/widgets "$SHA" success 'VERDICT: PASS 2026-11-03T09:30:00Z'
R="$T/failonly"; new_repo "$R" git@github.com:Acme/widgets.git; SHA=$(head_sha "$R")
verdict "$R" "$SHA" FAIL 2026-11-03T09:00:00Z
run_hook 'git push' "$R" "$PUSHED"; expect_posted 'only a FAIL section for the sha' Acme/widgets "$SHA" failure 'no judge verdict for this sha'

echo "# an ungated push: no verdict, or a verdict for another sha, is a failure status on the pushed sha"
R="$T/noverdict"; new_repo "$R" git@github.com:Acme/widgets.git; SHA=$(head_sha "$R")
run_hook 'git push -u origin IT-1-thing' "$R" "$PUSHED"
expect_posted 'no verdict file' Acme/widgets "$SHA" failure 'no judge verdict for this sha'
R="$T/othersha"; new_repo "$R" git@github.com:Acme/widgets.git; SHA=$(head_sha "$R")
verdict "$R" "$(git -C "$R" rev-parse main)" PASS 2026-11-03T08:00:00Z
run_hook 'git push -u origin IT-1-thing' "$R" "$PUSHED"
expect_posted 'a PASS for a different sha' Acme/widgets "$SHA" failure 'no judge verdict for this sha'
R="$T/prefix"; new_repo "$R" git@github.com:Acme/widgets.git; SHA=$(head_sha "$R")
verdict "$R" "${SHA:0:12}" PASS 2026-11-03T08:00:00Z
run_hook 'git push' "$R" "$PUSHED"; expect_posted 'an abbreviated sha in the header is not this sha' Acme/widgets "$SHA" failure 'no judge verdict for this sha'

echo "# pushes that did not happen post nothing"
R="$T/failed"; new_repo "$R" git@github.com:Acme/widgets.git; SHA=$(head_sha "$R"); verdict "$R" "$SHA" PASS 2026-11-03T10:00:00Z
run_hook 'git push -u origin IT-1-thing' "$R" "$REJECTED";                          expect_nothing 'a rejected push'
run_hook 'git push -u origin IT-1-thing' "$R" 'fatal: could not read from remote repository.'; expect_nothing 'a push that could not reach the remote'
run_hook 'git push -u origin IT-1-thing' "$R" '';                                   expect_nothing 'a push with no output'
run_hook 'git push -u origin IT-1-thing' "$R" "$PUSHED" true;                       expect_nothing 'an interrupted push'
run_hook 'git push --dry-run origin HEAD:refs/heads/gate-probe 2>&1 | tail -2' "$R" ' * [new branch]        HEAD -> gate-probe'; expect_nothing 'a dry run'
run_hook 'git status' "$R" 'On branch IT-1-thing';                                 expect_nothing 'git status'
run_hook 'echo "git push"' "$R" 'git push';                                         expect_nothing 'git push inside a quoted echo argument'
run_hook 'git pushy' "$R" "$PUSHED";                                                expect_nothing 'git pushy'
run_hook 'git push' "$T" "$PUSHED";                                                 expect_nothing 'a push from a folder that is not a git repo'

echo "# branches: main, release/* and a detached HEAD are never statused"
R="$T/branch"; new_repo "$R" git@github.com:Acme/widgets.git
gitq "$R" checkout main;          run_hook 'git push' "$R" "$UPDATED"; expect_nothing 'push on main'
gitq "$R" checkout -b release/qa; run_hook 'git push' "$R" "$UPDATED"; expect_nothing 'push on release/*'
gitq "$R" checkout --detach;      run_hook 'git push origin HEAD:refs/heads/x' "$R" "$PUSHED"; expect_nothing 'push from a detached HEAD'

echo "# the target repo: cd <wt> && git push and git -C <root> push resolve the repo named in the command"
A="$T/here"; new_repo "$A" git@github.com:Acme/widgets.git; verdict "$A" "$(head_sha "$A")" PASS 2026-11-03T07:00:00Z
B="$T/there"; new_repo "$B" https://github.com/Acme/other.git; SHA_B=$(head_sha "$B"); verdict "$B" "$SHA_B" PASS 2026-11-03T11:00:00Z
run_hook "cd $B && git push -u origin IT-1-thing 2>&1 | tail -8; echo \"push exit: \$?\"" "$A" "$PUSHED"
expect_posted 'cd <wt> && git push from another repo' Acme/other "$SHA_B" success 'VERDICT: PASS 2026-11-03T11:00:00Z'
run_hook "cd '$B' && git push" "$A" "$PUSHED";       expect_posted 'cd with a quoted path' Acme/other "$SHA_B" success 'VERDICT: PASS 2026-11-03T11:00:00Z'
run_hook "git -C $B push -u origin IT-1-thing" "$A" "$PUSHED"; expect_posted 'git -C <root> push from another repo' Acme/other "$SHA_B" success 'VERDICT: PASS 2026-11-03T11:00:00Z'
run_hook "git -C \"$B\" push" "$T" "$PUSHED";        expect_posted 'git -C with a quoted path from a non-repo cwd' Acme/other "$SHA_B" success 'VERDICT: PASS 2026-11-03T11:00:00Z'
run_hook "cd $B/nonexistent && git push" "$A" "$PUSHED"; expect_nothing 'a cd to a missing directory'
C="$T/nogithub"; new_repo "$C" /srv/git/local.git; verdict "$C" "$(head_sha "$C")" PASS 2026-11-03T07:00:00Z
run_hook 'git push' "$C" "$PUSHED";                 expect_nothing 'an origin that is not on GitHub'

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
