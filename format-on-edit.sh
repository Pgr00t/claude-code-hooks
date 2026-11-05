#!/usr/bin/env bash
# PostToolUse(Edit|Write) hook: format the one file that was touched, with the
# tooling of whichever repo it lives in (nearest pyproject.toml or package.json).
# Works for any repo and for files outside the session's primary folder.
set -u
INPUT=$(cat)
F=$(printf '%s' "$INPUT" | jq -r '.tool_response.filePath // .tool_input.file_path // empty')
[ -n "$F" ] && [ -f "$F" ] || exit 0
case "$F" in /*) ;; *) F="$(pwd)/$F" ;; esac

# Walk up to the repo root that owns this file.
DIR=$(dirname "$F"); ROOT=""
while [ "$DIR" != "/" ]; do
  if [ -f "$DIR/pyproject.toml" ] || [ -f "$DIR/package.json" ]; then ROOT="$DIR"; break; fi
  DIR=$(dirname "$DIR")
done
[ -n "$ROOT" ] || exit 0
cd "$ROOT" || exit 0

case "$F" in
  *.py)
    [ -f pyproject.toml ] || exit 0
    poetry run black -q "$F" && poetry run isort --profile black -q "$F" ;;
  *.ts|*.tsx|*.js|*.jsx)
    [ -f package.json ] || exit 0
    npx prettier --loglevel warn --write "$F" && npx eslint --fix "$F" ;;
  *.scss|*.css)
    [ -f package.json ] || exit 0
    [ -f .stylelintrc.json ] && npx stylelint --fix --config .stylelintrc.json "$F"
    npx prettier --loglevel warn --write "$F" ;;
  *.json|*.md)
    [ -f package.json ] && npx prettier --loglevel warn --write "$F" ;;
esac >/dev/null 2>&1
exit 0
