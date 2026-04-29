#!/usr/bin/env bash
#
# setup-jam-token.sh — interactive Jam personal access token setup.
#
# Usage:
#   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-jam-token.sh <targetRepo>
#
# Or — when the user is in a Claude Code session — they can paste this
# inline (the leading `!` runs the command in CC and the output lands in
# the conversation):
#
#   ! bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-jam-token.sh /path/to/repo
#
# What it does:
#   1. Opens https://jam.dev/account/api-keys in the default browser.
#   2. Prompts for the token (input hidden) via `read -s`.
#   3. Writes <targetRepo>/.thk/keys/jam.key with chmod 600 inside a
#      chmod 700 keys/ directory.
#   4. Prints the next step (re-run /thk).
#
# Idempotent — confirms before overwriting an existing token file.

set -euo pipefail

TARGET_REPO="${1:-}"

if [ -z "$TARGET_REPO" ]; then
  echo "Usage: setup-jam-token.sh <targetRepo>" >&2
  exit 1
fi

if [ ! -d "$TARGET_REPO" ]; then
  echo "✗ $TARGET_REPO is not a directory" >&2
  exit 1
fi

URL="https://jam.dev/account/api-keys"
KEYS_DIR="$TARGET_REPO/.thk/keys"
TOKEN_FILE="$KEYS_DIR/jam.key"

# ANSI helpers
bold()  { printf '\033[1m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }

echo ""
echo "$(bold "thk — Jam token setup")"
echo "$(dim "for $TARGET_REPO")"
echo ""

# Check existing token
if [ -f "$TOKEN_FILE" ]; then
  echo "An existing token file is already at $TOKEN_FILE."
  read -r -p "Replace it? [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Kept existing token. Re-run /thk <ticket-url> when ready."
    exit 0
  fi
fi

echo "Opening Jam token page: $URL"

# Open browser, best-effort cross-platform
if command -v open >/dev/null 2>&1; then
  open "$URL" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL" >/dev/null 2>&1 || true
elif command -v wslview >/dev/null 2>&1; then
  wslview "$URL" >/dev/null 2>&1 || true
else
  echo "$(dim "(couldn't auto-launch browser; visit the URL manually)")"
fi

echo ""
echo "1. Sign in to Jam if needed."
echo "2. Click 'Create personal access token' (or copy an existing one)."
echo "3. Paste it below."
echo ""
printf "Jam token (input hidden): "
# -s hides input on bash/zsh; trailing newline added by us
read -rs JAM_TOKEN || JAM_TOKEN=""
printf "\n"

# Trim any whitespace/newlines the user may have pasted
JAM_TOKEN=$(printf "%s" "$JAM_TOKEN" | tr -d '[:space:]')

if [ -z "$JAM_TOKEN" ]; then
  echo "$(dim "✗ Empty input — nothing saved.")"
  exit 1
fi

# Write atomically with strict perms before any bytes hit disk
mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"
umask 077
printf "%s" "$JAM_TOKEN" > "$TOKEN_FILE.tmp" && mv -f "$TOKEN_FILE.tmp" "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

echo ""
echo "$(green "✓") Wrote $TOKEN_FILE $(dim "(chmod 600 in chmod 700 keys/)")"
echo "$(green "✓") Re-run /thk on the same ticket to resume — the preflight will now pass."
