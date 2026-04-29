#!/usr/bin/env bash
#
# thk install — bootstrap thk into Claude Code with chosen runners and sources.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/thiagokroger/thk/main/install.sh | bash
#   ./install.sh [--target-repo PATH] [--non-interactive] [--profile NAME]
#
# What it does:
#   1. Verifies Claude Code is installed (Hand of the King is a Claude Code plugin).
#   2. Detects optional advisor runners (Codex CLI, Gemini CLI).
#   3. Asks which profile, ticket source MCP, and optional capture MCPs to use.
#   4. Writes <targetRepo>/.thk/config.json so /thk uses the chosen profile + sources.
#   5. Checks <targetRepo>/.gitignore for .thk/; if missing, prompts to add it (recommended).
#   6. Prints the /plugin marketplace add + /plugin install commands to paste into Claude Code.
#
# Idempotent — re-running prompts before overwriting an existing config.

set -euo pipefail

# --- Constants ---
THK_REPO="thiagokroger/thk"
MARKETPLACE_NAME="thiago-tools"
PLUGIN_NAME="thk"

# --- ANSI helpers ---
bold()   { printf '\033[1m%s\033[0m' "$1"; }
green()  { printf '\033[32m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
red()    { printf '\033[31m%s\033[0m' "$1"; }
dim()    { printf '\033[2m%s\033[0m' "$1"; }

step() { printf "\n%s %s\n" "$(bold "→")" "$1"; }
info() { printf "  %s\n" "$1"; }
warn() { printf "  %s %s\n" "$(yellow "!")" "$1"; }
fail() { printf "  %s %s\n" "$(red "✗")" "$1" >&2; exit 1; }
ok()   { printf "  %s %s\n" "$(green "✓")" "$1"; }

# --- Args ---
TARGET_REPO="${PWD}"
NON_INTERACTIVE=0
FORCE_PROFILE=""

print_help() {
  cat <<'HELP'
thk install — bootstrap thk into Claude Code with chosen runners and sources.

Usage:
  curl -fsSL https://raw.githubusercontent.com/thiagokroger/thk/main/install.sh | bash
  ./install.sh [--target-repo PATH] [--non-interactive] [--profile NAME]

What it does:
  1. Verifies Claude Code is installed (Hand of the King is a Claude Code plugin).
  2. Verifies `gh` CLI is installed; warns if not authenticated.
  3. Detects optional advisor runners (Codex CLI, Gemini CLI).
  4. Asks which profile, ticket source MCP, and optional capture MCPs to use.
  5. Writes <targetRepo>/.thk/config.json so /thk uses the chosen profile + sources.
  6. Checks <targetRepo>/.gitignore for the thk block; if missing, prompts to add it.
  7. Prints the /plugin marketplace add + /plugin install commands to paste into Claude Code.

Idempotent — re-running prompts before overwriting an existing config.
HELP
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-repo)     TARGET_REPO="$2"; shift 2;;
    --non-interactive) NON_INTERACTIVE=1; shift;;
    --profile)         FORCE_PROFILE="$2"; shift 2;;
    -h|--help)         print_help; exit 0;;
    *) fail "unknown argument: $1";;
  esac
done

# --- TTY availability for interactive prompts ---
# When the script is run via `curl … | bash`, stdin is the curl pipe — every
# interactive `read` would hit EOF and the script would die at the first
# prompt. Detect that and either route prompts to /dev/tty (the user's
# controlling terminal) or, if no tty exists at all (CI, sandboxed runners),
# force non-interactive defaults.
#
# `[ -r /dev/tty ]` tests file mode bits, not whether opening would succeed.
# In sandboxed environments /dev/tty exists with the right mode but opening
# it fails ("Device not configured"). The reliable check is to actually try
# opening it for read and write.
if (: </dev/tty) 2>/dev/null && (: >/dev/tty) 2>/dev/null; then
  HAS_TTY=1
else
  HAS_TTY=0
  if [ "$NON_INTERACTIVE" = 0 ]; then
    NON_INTERACTIVE=1
    NO_TTY_AUTO_FORCED=1
  fi
fi

# --- Banner ---
printf "\n%s\n"   "$(bold "thk install — Hand of the King")"
printf "%s\n"     "$(dim  "ticket → plan → council → execute → Draft PR")"
printf "%s\n\n"   "$(dim  "thk runs as a Claude Code plugin; this script wires it up.")"

if [ "${NO_TTY_AUTO_FORCED:-0}" = 1 ]; then
  printf "%s\n\n" "$(dim "(no controlling terminal — using non-interactive defaults: profile=claude_codex, all captures enabled.)")"
fi

# --- Target repo ---
step "Target repo"
# `.git` is a directory in normal checkouts and a regular file in git worktrees
# — `-e` (exists) accepts both, where `-d` would reject worktrees.
if [ ! -e "$TARGET_REPO/.git" ]; then
  fail "$TARGET_REPO is not a git repo. Run from inside the target repo, or pass --target-repo PATH."
fi
ok "$TARGET_REPO"

# --- Detect Claude Code (required) ---
step "Detecting Claude Code (required)"
HAS_CLAUDE=0
if command -v claude >/dev/null 2>&1; then HAS_CLAUDE=1; fi
if [ -d "$HOME/.claude" ]; then HAS_CLAUDE=1; fi
if [ "$HAS_CLAUDE" = 0 ]; then
  warn "Claude Code not detected on this machine."
  info "thk is a Claude Code plugin. Install Claude Code first:"
  info "  https://docs.claude.com/claude-code"
  fail "Claude Code is required."
fi
ok "Claude Code detected"

# --- Verify gh CLI (required for plan publish + PR open) ---
step "Detecting gh CLI (required)"
if ! command -v gh >/dev/null 2>&1; then
  warn "gh CLI not detected on this machine."
  info "thk uses gh to publish plans as GitHub issues and open Draft PRs."
  info "Install: https://cli.github.com"
  fail "gh CLI is required."
fi
if ! gh auth status >/dev/null 2>&1; then
  warn "gh CLI is installed but not authenticated."
  info "Run \`gh auth login\` (or \`gh auth setup-git\` if SSH-only) before invoking /thk."
  info "(Continuing — install can finish, but the first /thk run will fail until you authenticate.)"
else
  ok "gh CLI authenticated"
fi

# --- Detect optional advisor runners ---
step "Detecting optional advisor runners"
HAS_CODEX=0
HAS_GEMINI=0
if command -v codex  >/dev/null 2>&1 || [ -d "$HOME/.codex"  ]; then HAS_CODEX=1;  ok "Codex CLI detected";  else printf "  %s\n" "$(dim "· Codex CLI not detected")";  fi
if command -v gemini >/dev/null 2>&1 || [ -d "$HOME/.gemini" ]; then HAS_GEMINI=1; ok "Gemini CLI detected"; else printf "  %s\n" "$(dim "· Gemini CLI not detected")"; fi

# --- Detect gum for the TUI; fall back to bash builtins otherwise ---
USE_GUM=0
if command -v gum >/dev/null 2>&1; then
  USE_GUM=1
fi

# All interactive reads route through /dev/tty so the script works under
# `curl … | bash` (where stdin is the script content, not a terminal). gum
# already prefers /dev/tty when available, but we redirect explicitly for
# the bash-builtin fallbacks (`select`, `read`).

# Single-choice prompt. Prints the chosen string to stdout.
choose_one() {
  local prompt="$1"; shift
  local options=("$@")
  if [ "$USE_GUM" = 1 ]; then
    gum choose --header "$prompt" "${options[@]}" </dev/tty
  else
    printf "\n%s\n" "$prompt" >&2
    PS3="> "
    select choice in "${options[@]}"; do
      [ -n "${choice:-}" ] && { echo "$choice"; break; }
    done </dev/tty
  fi
}

# Multi-choice prompt. Prints chosen strings (one per line) to stdout.
choose_many() {
  local prompt="$1"; shift
  local options=("$@")
  if [ "$USE_GUM" = 1 ]; then
    gum choose --no-limit --header "$prompt" "${options[@]}" </dev/tty || true
  else
    printf "\n%s\n" "$prompt" >&2
    printf "%s\n" "$(dim "(comma-separated indices, blank for none)")" >&2
    local i=1
    for opt in "${options[@]}"; do
      printf "  %d) %s\n" "$i" "$opt" >&2
      i=$((i+1))
    done
    local indices
    read -r -p "> " indices </dev/tty
    [ -z "$indices" ] && return 0
    IFS=',' read -ra parts <<< "$indices"
    for idx in "${parts[@]}"; do
      idx=$(echo "$idx" | tr -d ' ')
      [ -n "$idx" ] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#options[@]}" ] && printf "%s\n" "${options[$((idx-1))]}"
    done
  fi
}

confirm() {
  local prompt="$1"
  if [ "$USE_GUM" = 1 ]; then
    gum confirm "$prompt" </dev/tty
    return $?
  else
    local reply
    read -r -p "$prompt (y/N) " reply </dev/tty
    [[ "$reply" =~ ^[Yy]$ ]]
  fi
}

# --- Pick profile, source, captures ---
PROFILE=""
SOURCE="linear"
CAPTURES=()

if [ "$NON_INTERACTIVE" = 1 ]; then
  PROFILE="${FORCE_PROFILE:-claude_codex}"
  CAPTURES=("jam" "figma" "planetscale" "notion")
elif [ -n "$FORCE_PROFILE" ]; then
  PROFILE="$FORCE_PROFILE"
  step "Profile (forced via --profile)"
  ok "$PROFILE"
else
  step "Pick a profile (matches config/profiles.json)"
  PROFILE_OPTIONS=("claude_only — Claude for every role")
  if [ "$HAS_CODEX" = 1 ]; then
    PROFILE_OPTIONS+=("claude_codex — Claude council, Codex CLI Counselor (recommended default)")
    PROFILE_OPTIONS+=("codex_with_opus_counselor — Codex CLI for review roles, Claude Opus counselor")
    PROFILE_OPTIONS+=("codex_only — Codex CLI for model work (capture/shipping still via Claude Code)")
  fi
  if [ "$HAS_GEMINI" = 1 ]; then
    PROFILE_OPTIONS+=("gemini_only — Gemini CLI for model work via command-template adapter")
  fi
  PROFILE_OPTIONS+=("portable_sequential — emit prompts for manual or external execution")
  CHOSEN=$(choose_one "Profile?" "${PROFILE_OPTIONS[@]}")
  PROFILE=$(printf "%s" "$CHOSEN" | awk -F' — ' '{print $1}')
  ok "profile: $PROFILE"
fi

if [ "$NON_INTERACTIVE" = 0 ]; then
  step "Pick the ticket source MCP"
  SOURCE_OPTIONS=("linear — Linear MCP (only currently wired)")
  CHOSEN=$(choose_one "Ticket source?" "${SOURCE_OPTIONS[@]}")
  SOURCE=$(printf "%s" "$CHOSEN" | awk -F' — ' '{print $1}')
  ok "source: $SOURCE"

  step "Pick the optional capture MCPs"
  ALL_CAPTURES=("jam" "figma" "planetscale" "notion")
  CAPTURES=()
  while IFS= read -r line; do
    [ -n "$line" ] && CAPTURES+=("$line")
  done < <(choose_many "Which capture MCPs to enable? (toggle with space, enter to confirm)" "${ALL_CAPTURES[@]}")
  if [ "${#CAPTURES[@]}" -eq 0 ]; then
    warn "No optional captures enabled — only the ticket source will be captured."
  else
    ok "captures: ${CAPTURES[*]}"
  fi
fi

# --- Write <targetRepo>/.thk/config.json ---
step "Writing $TARGET_REPO/.thk/config.json"
mkdir -p "$TARGET_REPO/.thk"
CONFIG_PATH="$TARGET_REPO/.thk/config.json"

if [ -f "$CONFIG_PATH" ]; then
  warn "Config already exists at $CONFIG_PATH"
  if [ "$NON_INTERACTIVE" = 0 ]; then
    if ! confirm "Overwrite?"; then
      fail "Aborted — existing config preserved."
    fi
  fi
fi

# Build captures JSON array
captures_json="["
for i in "${!CAPTURES[@]}"; do
  [ "$i" -gt 0 ] && captures_json+=", "
  captures_json+="\"${CAPTURES[$i]}\""
done
captures_json+="]"

cat > "$CONFIG_PATH" <<EOF
{
  "version": 1,
  "default_profile": "$PROFILE",
  "sources": {
    "ticket": "$SOURCE"
  },
  "mcps": {
    "captures": $captures_json
  }
}
EOF
ok "wrote $CONFIG_PATH"

# --- Optional Jam token for video-frame extraction ---
# The Jam MCP itself works without this token. The token is only needed when
# capture-jam wants to download the raw recording and ffmpeg-extract frames at
# WebVTT cue timestamps. Lives under .thk/keys/ — a dedicated secrets dir kept
# at chmod 700, so future tokens (linear, github, …) follow the same pattern.
if [ "${#CAPTURES[@]}" -gt 0 ] && printf '%s\n' "${CAPTURES[@]}" | grep -qx jam; then
  step "Jam token (optional, only used for video-frame extraction)"
  KEYS_DIR="$TARGET_REPO/.thk/keys"
  TOKEN_FILE="$KEYS_DIR/jam.key"
  SKIP_TOKEN=0

  if [ -f "$TOKEN_FILE" ]; then
    info "existing token at $TOKEN_FILE"
    if [ "$NON_INTERACTIVE" = 1 ]; then
      ok "kept existing token (non-interactive)"
      SKIP_TOKEN=1
    elif ! confirm "Replace it?"; then
      ok "kept existing token"
      SKIP_TOKEN=1
    fi
  fi

  if [ "$SKIP_TOKEN" = 0 ]; then
    if [ "$NON_INTERACTIVE" = 1 ]; then
      warn "non-interactive — skipped Jam token prompt"
      info "set later via env var JAM_TOKEN, or write the token to $TOKEN_FILE"
    else
      info "Jam capture itself runs via the Jam MCP and needs no extra setup."
      info "If you also want capture-jam to ffmpeg-extract frames at transcript"
      info "timestamps, paste a Jam personal access token below. Skip otherwise —"
      info "the skill degrades gracefully (framesAvailable: false)."
      if confirm "Paste a Jam token now?"; then
        printf "  token (input hidden): "
        # -s hides input on bash/zsh; trailing newline added by us.
        # </dev/tty so curl|bash piping doesn't break the prompt.
        read -rs JAM_TOKEN_INPUT </dev/tty || JAM_TOKEN_INPUT=""
        printf "\n"
        # Trim any whitespace/newlines the user may have pasted
        JAM_TOKEN_INPUT=$(printf "%s" "$JAM_TOKEN_INPUT" | tr -d '[:space:]')
        if [ -n "$JAM_TOKEN_INPUT" ]; then
          # Create the secrets dir locked-down (chmod 700) and write the token
          # atomically with strict perms before any bytes hit disk.
          mkdir -p "$KEYS_DIR"
          chmod 700 "$KEYS_DIR"
          umask 077
          printf "%s" "$JAM_TOKEN_INPUT" > "$TOKEN_FILE.tmp" && mv -f "$TOKEN_FILE.tmp" "$TOKEN_FILE"
          chmod 600 "$TOKEN_FILE"
          ok "wrote $TOKEN_FILE (chmod 600 in chmod 700 keys/)"
        else
          warn "empty input — no token saved"
        fi
      else
        warn "skipped — set later via env var JAM_TOKEN or by writing $TOKEN_FILE"
      fi
    fi
  fi
fi

# --- .gitignore check for .thk/ ---
# Recommended. Only the transient + per-developer pieces are ignored;
# policies.json and agents/*.md (team-shared) commit naturally.
step ".gitignore check"
GITIGNORE="$TARGET_REPO/.gitignore"
GITIGNORE_MARKER="# thk per-project state — sessions/keys/config.json are gitignored; policies.json + agents/*.md commit"

if [ -f "$GITIGNORE" ] && grep -qxF "$GITIGNORE_MARKER" "$GITIGNORE"; then
  ok ".gitignore already has the thk block"
else
  if [ -f "$GITIGNORE" ]; then
    info "thk block not found in $GITIGNORE"
  else
    info "no .gitignore at $TARGET_REPO"
  fi
  info "$(dim "(recommended — keeps sessions / secrets / per-developer config out of git; policies.json + agents/*.md remain team-shared)")"

  # Default to yes. Non-interactive mode auto-adds (the recommended path).
  ADD_GITIGNORE=1
  if [ "$NON_INTERACTIVE" = 0 ]; then
    if [ "$USE_GUM" = 1 ]; then
      gum confirm --default=true "Add the thk block to .gitignore?" </dev/tty || ADD_GITIGNORE=0
    else
      read -r -p "  Add the thk block to .gitignore? [Y/n] " reply </dev/tty
      [[ "$reply" =~ ^[Nn]$ ]] && ADD_GITIGNORE=0
    fi
  fi

  if [ "$ADD_GITIGNORE" = 1 ]; then
    # If file exists and doesn't end in newline, add one before our block
    if [ -f "$GITIGNORE" ] && [ -s "$GITIGNORE" ] && [ -n "$(tail -c 1 "$GITIGNORE" 2>/dev/null)" ]; then
      printf "\n" >> "$GITIGNORE"
    fi
    cat >> "$GITIGNORE" <<EOF
$GITIGNORE_MARKER
.thk/sessions/
.thk/keys/
.thk/config.json
EOF
    ok "added thk gitignore block (.thk/sessions/, .thk/keys/, .thk/config.json) to .gitignore"
  else
    warn "skipped — .thk/sessions/, .thk/keys/, .thk/config.json will appear in 'git status'. Run:"
    warn "    cat >> .gitignore <<'EOF'"
    warn "    $GITIGNORE_MARKER"
    warn "    .thk/sessions/"
    warn "    .thk/keys/"
    warn "    .thk/config.json"
    warn "    EOF"
  fi
fi

# --- Final instructions ---
step "Next — paste these into a Claude Code session"
printf "\n  %s\n"  "$(bold "1) Register the marketplace + install the plugin")"
printf "     %s\n" "/plugin marketplace add $THK_REPO"
printf "     %s\n" "/plugin install $PLUGIN_NAME@$MARKETPLACE_NAME"

printf "\n  %s\n"  "$(bold "2) Confirm these MCP servers are wired in your Claude Code MCP config")"
printf "     %s\n" "Required: $SOURCE"
if [ "${#CAPTURES[@]}" -gt 0 ]; then
  printf "     %s\n" "Optional: ${CAPTURES[*]}"
else
  printf "     %s\n" "Optional: $(dim "(none selected)")"
fi
printf "     %s\n" "$(dim "Reference: https://docs.claude.com/claude-code/mcp")"

printf "\n  %s\n"  "$(bold "3) Run thk")"
printf "     %s\n" "/thk <ticket-url>"

printf "\n  %s\n" "$(dim "Config saved at $CONFIG_PATH — edit anytime to change profile / source / captures.")"
printf "\n%s %s\n\n" "$(green "✓")" "thk install complete."
