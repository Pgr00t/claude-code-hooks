# The ungated push of 2026-11-02: what happened, what reproduces

Written 2026-11-03 from the session transcript, the desktop app's log, and a throwaway reproduction.

## Verdict

The gate was not skipped. It was started for the push, the MacBook went to sleep while it ran, and when the
machine woke the hook's 900 s wall-clock timeout had expired. Claude Code records a timed-out PreToolUse hook
as `hook_cancelled` and runs the tool anyway: a hook timeout fails open. The push landed 4 s after the wake.
The same thing happened to two more Bash calls in that session, one of which should have been denied in
milliseconds. The fail-open on timeout reproduces headlessly on the CLI on PATH (2.1.296) and on the binary the
desktop app ran that night (2.1.309). "Auto mode skips user-level hooks" does not reproduce: in auto and in
bypassPermissions the gate ran and denied the push.

## Evidence from the session (transcript `ba88a4a2`, app session `local_fb940677`, Claude Code 2.1.309, auto)

The transcript records one attachment per hook run. 63 Bash calls got `hook_success` with stdout `{}` within
milliseconds (the gate's "not a push" path). Three got `hook_cancelled` with `timedOut: true, timeoutMs: 900000`:

| Bash call (UTC, IST)                                              | hook_cancelled (IST)   | durationMs | tool ran after | app log: main process blocked (sleep), wake at                  |
| ----------------------------------------------------------------- | ---------------------- | ---------- | -------------- | --------------------------------------------------------------- |
| 23:57:08Z (05:27:08) `cd <root> && git push -u origin dependabot-security-fixes` | 00:13:13Z (05:43:13) | 964 380 | push landed 00:13:17Z, PR #1477 head 392071bd | blocked 923 982 ms, wake 05:43:12 |
| 05:13:40Z (10:43:40) `git checkout --detach && git push --dry-run origin HEAD:refs/heads/gate-probe` (the hook ran before the checkout, so it saw the packeted branch and started the full gate) | 05:30:49Z (11:00:49) | 1 028 962 | dry run ran 05:30:53Z | blocked 1 006 958 ms, wake 11:00:49 |
| 05:49:25Z (11:19:25) `cat >> memory/judge-gate-hook.md <<'EOF' ...` (the heredoc text contains `&& git push`, so the gate's regex took it for a push) | 06:05:51Z (11:35:51) | 980 786 | append ran 06:05:51Z | blocked 955 980 ms, wake 11:35:50 |

Each of the three calls was issued within 25 s of a wake (`[event-loop-stall] main process blocked for ...ms
[likely sleep: power_event]` in `~/Library/Logs/Claude/main.log` at 05:27:01, 10:43:15 and 11:19:07 IST): the
machine woke briefly, the model's turn resumed and issued the Bash call, the hook was spawned, and the machine
slept again before it finished. The hook timer is wall-clock, so it had expired by the next wake. The first two
calls ran the full gate (suite and judge) on the packeted branch, which made no progress while the machine slept.
The third is the telling one: its `cd <root>` target does not exist, so the gate denies it in under a second, yet
it was cancelled too, so the hook process itself was not running when the clock ran out.

The session's model never saw the gap ("went through in seconds" in the memory note is what it looked like
from inside a suspended process). The PASS on record for #1477 was produced afterwards by piping the hook its
JSON by hand; that run itself exceeded the Bash tool's 600 s and was moved to the background, so the judge was
slow that night as well, which matters because the gate's own budget is tight: `timeout 840` for the judge plus
the suite inside a 900 s hook.

Not the cause, but seen in the log that night: the app updated its bundled CLI from 2.1.308 to 2.1.309 at
01:03 IST, and at the same minute logged `[confinedInstall] could not read the Claude Code settings files` for
the `.claude/settings.local.json` symlinks in worktrees (`ERR_SAFE_FS_SYMLINK`). That concerns the app's own
reading of project settings; the user-level hooks loaded fine, as the 63 `hook_success` rows show.

## Reproduction (2026-11-03)

Setup, all under this session's scratchpad: a bare `origin.git`; a work checkout on branch `feat-probe` (one
commit past `main`, a `.claude/judge/` folder, no packet); a wrapper `gate-wrapper.sh` that appends
`<utc> <pwd>` to `~/.claude/hooks/tests/gate-invocations.log` and then `exec`s the real `judge-gate.sh`
unchanged; a copy of the hooks block pointing at the wrapper (`settings-repro.json`, timeout 900); and a second
copy pointing at `slow-deny.sh`, which sleeps 20 s and then denies, with `timeout: 5` (`settings-timeout.json`).
Each headless run: `claude -p "<run exactly: git push -u origin feat-probe>" --model claude-haiku-5-5
--permission-mode <mode> --allowedTools Bash --setting-sources project --settings <copy> --output-format json
--no-session-persistence`, with `CLAUDECODE` unset. `origin` was reset between cases.

| case                                                        | CLI                     | gate wrapper ran | push landed | result                                                                 |
| ----------------------------------------------------------- | ----------------------- | ---------------- | ----------- | ---------------------------------------------------------------------- |
| plain shell: `git push -u origin feat-probe` from bash      | none                    | no (0 lines)     | yes         | the hook is a Claude-side check only; git itself has no gate           |
| `claude -p`, `--permission-mode auto`, real gate            | 2.1.296                 | yes              | no          | denied: "no packet at .claude/judge/feat-probe.md"                     |
| `claude -p`, `--permission-mode bypassPermissions`, real gate | 2.1.296               | yes              | no          | denied the same way: bypass does not skip hooks                        |
| `claude -p`, auto, slow deny with `timeout: 5`              | 2.1.296                 | started, never reached its deny | yes | the model reported "The push succeeded"                        |
| `claude -p`, auto, slow deny with `timeout: 5`              | 2.1.309 (app-bundled binary, `~/Library/Application Support/Claude/claude-code/2.1.309/.../MacOS/claude`) | started, never reached its deny | yes | same: a timed-out PreToolUse hook fails open |

In the same desktop-app session that wrote this document (auto mode, 2.1.309), two compound Bash commands that
happened to contain `git -C ... push` and `&& git push` text were denied by the gate within a second, and a
sibling session's detached-HEAD dry-run probe was denied too. The gate fires in the app today.

## Most likely cause

A system sleep between the hook's spawn and its completion, in a session whose turn resumed on a short wake.
The hook's timeout is wall-clock; Claude Code treats a PreToolUse hook that exceeds it as cancelled and lets the
tool run. Any PreToolUse hook on this machine is exposed to this when the lid is closed mid-turn; the gate is
exposed most because it legitimately runs for minutes, and its 900 s budget was already close to the judge's own
840 s timeout. (On 2026-11-03 another session raised the gate's timeout to 7200 in `~/.claude/settings.json`;
that widens the window but does not change what happens when the window closes.)

## Containment

Nothing downstream noticed the ungated push. Now `~/.claude/hooks/judge-status.sh` (PostToolUse, matcher
`Bash`) posts a commit status on the pushed head after every successful feature-branch push: context
`judge-gate/verdict`, `success` with `VERDICT: PASS <utc>` when a PASS section for that exact sha exists in
`.claude/judge/<branch>.verdict.md`, otherwise `failure` with `no judge verdict for this sha`. A CI job in each
repo fails a feature-branch PR whose head has no such success status, so a push the gate never finished judging
is red on the PR instead of invisible. Tests: `bash ~/.claude/hooks/tests/test-judge-status.sh` (77 cases).
Still true after this: a status hook is also a hook, so a sleep can lose the status post too; the CI job then
fails the PR for lack of a status, which is the right direction to fail in.
