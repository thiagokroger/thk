#!/usr/bin/env bash
# Append a timestamped entry to a thk session log.
#
# Usage:
#   log.sh <session-root | contextDir | worktree> <actor> <event> <message...>
#
# Arguments:
#   $1  — any path that resolves to the session root. Accepts:
#           <targetRepo>/.claude/.thk/sessions/<id>/          (itself)
#           <targetRepo>/.claude/.thk/sessions/<id>/context/  (sibling)
#           <targetRepo>/.claude/.thk/sessions/<id>/worktree/ (sibling)
#   $2  — actor slug: "hand", "grand-maester", "master-of-laws",
#         "lord-commander", "master-of-coin", "master-of-whisperers",
#         "master-of-ships", "counselor-altman", or a skill/capture name.
#   $3  — event kind:
#           step-start | step-done | dispatch |
#           skill-invoke | skill-return | decision | error
#   $4.. — free-form single-line message. Multiple args are joined with spaces.
#
# Behavior:
#   - Creates <session-root>/log.md on first call with a header.
#   - Appends one markdown line per call:
#       `<UTC timestamp>` **<actor>** _<event>_ — <message>
#   - Short appends (<4KB) are atomic on POSIX — safe for concurrent
#     writes from parallel sub-agents.
#
# Example:
#   bash scripts/log.sh "$contextDir" hand step-start "Step 1d — dispatching swarm of 6 whisperers"
#   bash scripts/log.sh "$workdir"    grand-maester skill-invoke "review-plan-history planPath=plan.md"

set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <session-root|contextDir|worktree> <actor> <event> <message...>" >&2
  exit 64
fi

raw="${1%/}"
actor="$2"
event="$3"
shift 3
message="$*"

# Resolve to the session root. If $raw contains a `context/` child, $raw IS
# the session root. If $raw's parent contains `context/`, $raw is a sibling
# (contextDir or worktree) and parent is the session root. Otherwise trust
# the caller's path.
if [ -d "$raw/context" ]; then
  session_root="$raw"
elif [ -d "$(dirname "$raw")/context" ]; then
  session_root="$(dirname "$raw")"
else
  session_root="$raw"
fi

log_file="$session_root/log.md"
mkdir -p "$session_root"

if [ ! -f "$log_file" ]; then
  session_id="$(basename "$session_root")"
  printf '# Session Log — %s\n\n' "$session_id" > "$log_file"
  printf '_Append-only chronological record. Every agent interaction, every skill invocation, every decision, every error._\n\n' >> "$log_file"
  printf -- '---\n\n' >> "$log_file"
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '`%s` **%s** _%s_ — %s\n\n' "$timestamp" "$actor" "$event" "$message" >> "$log_file"
