#!/usr/bin/env bash
# Append a timestamped entry to a thk session log.
#
# Usage:
#   log.sh <session-root | contextDir | worktree> <actor> <event> <message...>
#
# Arguments:
#   $1  — any path that resolves to the session root. Accepts:
#           <targetRepo>/.thk/sessions/<id>/          (itself)
#           <targetRepo>/.thk/sessions/<id>/context/  (sibling)
#           <targetRepo>/.thk/sessions/<id>/worktree/ (sibling)
#   $2  — actor slug: "hand", "grand-maester", "master-of-laws",
#         "lord-commander", "master-of-coin", "master-of-whisperers",
#         "master-of-ships", "counselor-altman", or a skill/capture name.
#   $3  — event kind:
#           step-start | step-done | dispatch |
#           skill-invoke | dispatch-detail | skill-return |
#           decision | error
#   $4.. — free-form single-line message. Multiple args are joined with spaces.
#
# Optional multi-line body (for `dispatch-detail` and similar):
#   Pipe a multi-line body on stdin. Each line gets prefixed with `> ` so the
#   body renders as a markdown blockquote — visually grouped under the header
#   line, collapsible-feeling in IDE/GitHub markdown viewers, still grep-able.
#
#   Convention for `dispatch-detail` body: one line per side-effect action.
#   Side-effect = MCP tool call, Bash invocation, Write, Edit. Read-only
#   actions (Read, Grep, Glob) should NOT be logged — they're noise.
#
#   Format suggestion: `category: action → result`. Examples:
#     tool: mcp__figma__get_design_context (node=5537:31825) → 23KB context
#     bash: curl -sL → screenshots/1.png (143KB)
#     write: context.md (24KB), metadata.md (3KB), README.md (1.2KB)
#
# Behavior:
#   - Creates <session-root>/log.md on first call with a header.
#   - Single-line entry (no stdin):
#       `<UTC timestamp>` **<actor>** _<event>_ — <message>
#   - Multi-line entry (stdin piped, non-empty):
#       `<UTC timestamp>` **<actor>** _<event>_ — <message>
#       > body line 1
#       > body line 2
#       > ...
#   - The whole entry (header + body) is written in a single fwrite so concurrent
#     parallel sub-agents don't interleave each other's bodies. Short appends
#     (<~4KB) are atomic on POSIX — keep bodies under that for safety.
#
# Example — single-line:
#   bash scripts/log.sh "$contextDir" hand step-start "Step 1d — swarm of 6 whisperers"
#
# Example — multi-line dispatch-detail:
#   bash scripts/log.sh "$contextDir" master-of-whisperers dispatch-detail \
#     "_capture-figma node=5537-31825" <<'EOF'
#   tool: mcp__figma__get_design_context (fileKey=qzz76, node=5537:31825) → 23KB
#   tool: mcp__figma__get_metadata → 3KB
#   tool: mcp__figma__get_variable_defs → empty
#   tool: mcp__figma__get_screenshot → 1 URL
#   bash: curl -sL → screenshots/1.png (143KB)
#   write: README.md (1.1KB), context.md (24KB), metadata.md (3KB), screenshots/1.png
#   EOF

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

# Buffer the full entry (header + optional body) into a single string so the
# write is atomic — parallel subagents writing dispatch-details concurrently
# won't interleave their bodies. Use `printf -v` (preserves newlines) instead
# of `$(...)` (which strips trailing newlines).
printf -v entry '`%s` **%s** _%s_ — %s\n' "$timestamp" "$actor" "$event" "$message"

# Body-from-stdin is opt-in by event name — only `dispatch-detail` reads stdin
# for a multi-line body. This avoids hanging on TTY-less stdin in shells like
# Claude Code's Bash tool (where stdin is piped from /dev/null but `[ -t 0 ]`
# heuristics misfire).
#
# Convention: when you call `log.sh ... dispatch-detail "<msg>"`, ALWAYS pipe
# a body via heredoc or redirection. If no body is supplied (stdin is empty),
# the entry still writes successfully — just with no blockquote section.
if [ "$event" = "dispatch-detail" ]; then
  body="$(cat)"
  if [ -n "$body" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      printf -v line_entry '> %s\n' "$line"
      entry="${entry}${line_entry}"
    done <<< "$body"
  fi
fi

# Trailing blank line for visual separation in the rendered log
entry="${entry}"$'\n'

printf '%s' "$entry" >> "$log_file"
