#!/usr/bin/env bash
#
# sync-local-plugin.sh — pull the latest pushed state of this plugin into
# your local Claude Code install, without needing /plugin update or a reinstall.
#
# Usage:
#   ./scripts/sync-local-plugin.sh
#
# What it does:
#   1. `git fetch + reset --hard origin/<default-branch>` the marketplace clone at
#      ~/.claude/plugins/marketplaces/thiago-tools/
#   2. Same for every cached plugin version under
#      ~/.claude/plugins/cache/thiago-tools/thk/*/
#   3. Prints the installed version + a reminder to run `/plugin update thk`
#      in Claude Code *only* when the version string in plugin.json has bumped —
#      otherwise the pulled files are enough and no in-CC command is needed.
#
# Safe-ish:
#   - Won't run if a target directory has uncommitted local edits.
#   - Doesn't touch any non-thiago-tools plugin.
#   - Read-only on the remote; only your local ~/.claude cache is modified.

set -euo pipefail

MARKETPLACE_NAME="thiago-tools"
PLUGIN_NAME="thk"
REMOTE_NAME="origin"

CLAUDE_ROOT="${CLAUDE_ROOT:-$HOME/.claude}"
MARKETPLACE_DIR="$CLAUDE_ROOT/plugins/marketplaces/$MARKETPLACE_NAME"
CACHE_ROOT="$CLAUDE_ROOT/plugins/cache/$MARKETPLACE_NAME/$PLUGIN_NAME"

bold() { printf '\033[1m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
red() { printf '\033[31m%s\033[0m' "$1"; }

fail() {
  echo "$(red "✗") $1" >&2
  exit 1
}

sync_git_dir() {
  local label="$1"
  local dir="$2"

  if [ ! -d "$dir/.git" ]; then
    echo "  $(yellow "⚠") $label: not a git clone at $dir — skipping"
    return 0
  fi

  # Claude Code drops a `.orphaned_at` file inside version dirs it no longer
  # considers installed (e.g. after /plugin update moves to a new version).
  # Don't touch orphaned versions — they are CC-managed tombstones, not live.
  if [ -f "$dir/.orphaned_at" ]; then
    echo "  $(yellow "·") $label: orphaned by Claude Code — skipping"
    return 0
  fi

  # Refuse to stomp on genuine local edits. Dev-editing inside the cache is
  # unusual but possible; losing that work silently would be worse than
  # failing loudly. Excludes the known-safe .orphaned_at marker above.
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    echo "  $(red "✗") $label: uncommitted changes in $dir — skipping"
    return 1
  fi

  # Resolve the default branch on the remote so we work regardless of main/master.
  local default_ref
  default_ref=$(git -C "$dir" symbolic-ref "refs/remotes/$REMOTE_NAME/HEAD" 2>/dev/null | sed "s@^refs/remotes/$REMOTE_NAME/@@") || true
  if [ -z "$default_ref" ]; then
    git -C "$dir" remote set-head "$REMOTE_NAME" --auto >/dev/null 2>&1 || true
    default_ref=$(git -C "$dir" symbolic-ref "refs/remotes/$REMOTE_NAME/HEAD" 2>/dev/null | sed "s@^refs/remotes/$REMOTE_NAME/@@") || true
  fi
  default_ref="${default_ref:-main}"

  git -C "$dir" fetch --quiet --prune "$REMOTE_NAME"
  git -C "$dir" reset --quiet --hard "$REMOTE_NAME/$default_ref"
  local new_sha
  new_sha=$(git -C "$dir" rev-parse --short HEAD)
  echo "  $(green "✓") $label → $new_sha ($default_ref)"
}

echo "$(bold "Syncing local Claude Code plugin cache with origin…")"

# Marketplace clone — carries marketplace.json that Claude Code reads for version checks.
echo ""
echo "Marketplace clone:"
sync_git_dir "marketplace" "$MARKETPLACE_DIR" || fail "marketplace sync aborted"

# Installed plugin cache — one subdir per installed version. Almost always exactly one.
echo ""
echo "Installed plugin cache:"
if [ ! -d "$CACHE_ROOT" ]; then
  echo "  $(yellow "⚠") no cached install at $CACHE_ROOT — is the plugin installed?"
  echo "    install with:  /plugin install $PLUGIN_NAME@$MARKETPLACE_NAME"
else
  found_any=0
  for version_dir in "$CACHE_ROOT"/*/; do
    [ -d "$version_dir" ] || continue
    found_any=1
    version_tag=$(basename "$version_dir")
    sync_git_dir "$PLUGIN_NAME@$version_tag" "${version_dir%/}" || fail "plugin cache sync aborted"
  done
  if [ "$found_any" = 0 ]; then
    echo "  $(yellow "⚠") no version subdirs under $CACHE_ROOT"
  fi
fi

# Version-drift check — has the pushed marketplace.json bumped the version past
# what CC has recorded as installed? If yes, `/plugin update` is needed so CC
# moves the cache to a new version directory.
echo ""
PUSHED_VERSION=$(
  jq -r --arg n "$PLUGIN_NAME" '.plugins[] | select(.name == $n) | .version' \
    "$MARKETPLACE_DIR/.claude-plugin/marketplace.json" 2>/dev/null || echo ""
)
INSTALLED_VERSION=$(
  jq -r --arg key "$PLUGIN_NAME@$MARKETPLACE_NAME" '.plugins[$key][0].version' \
    "$CLAUDE_ROOT/plugins/installed_plugins.json" 2>/dev/null || echo ""
)

if [ -n "$PUSHED_VERSION" ] && [ -n "$INSTALLED_VERSION" ] && [ "$PUSHED_VERSION" != "$INSTALLED_VERSION" ]; then
  echo "$(yellow "→ Version bump detected:") installed $INSTALLED_VERSION, pushed $PUSHED_VERSION"
  echo "  Run this in your Claude Code session to reconcile the install path:"
  echo "    $(bold "/plugin update $PLUGIN_NAME")"
else
  echo "$(green "✓ Files synced.") No version bump; Claude Code will use the updated files on its next run."
  echo "  (If things still look stale, restart your Claude Code session.)"
fi
