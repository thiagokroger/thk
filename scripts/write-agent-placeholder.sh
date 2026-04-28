#!/usr/bin/env bash
# Write a per-agent project-instruction placeholder file.
#
# Usage: write-agent-placeholder.sh <member> <target-path>
#
# Each placeholder is a single HTML comment explaining what the file is
# for and what kind of project-specific guidance fits. The agent treats a
# comment-only file as "no project instructions yet" and falls through to
# its built-in defaults; team members extend behavior by writing real
# guidance below the comment block.
#
# Idempotent — refuses to overwrite an existing file. Caller should
# pre-check with `[ -f "$target" ]`, but this is a belt-and-suspenders
# guard.

set -euo pipefail

member="${1:?member name required}"
target="${2:?target path required}"

if [ -e "$target" ]; then
  echo "write-agent-placeholder: $target already exists; refusing to overwrite." >&2
  exit 0
fi

case "$member" in
  master-of-whisperers)
    title="Master of Whisperers"
    specialty="URL-driven intelligence gatherer (Linear, Jam, Figma, …)"
    examples='  - "When capturing Jams, always include console + network captures even on screenshot-only recordings — past incidents have hinged on quiet errors."
  - "Linear tickets in this repo often link to Notion specs; capture those too if the link panel includes a docs.notion.site URL."
  - "Figma node ids in this codebase usually map to a `<ComponentName>.tsx` file in `src/components/<feature>/` — note the mapping when you see one."'
    ;;
  master-of-ships)
    title="Master of Ships"
    specialty="git plumbing — branches, commits, pushes, PRs, GitHub issues, Linear updates"
    examples='  - "Branch names follow `<author>/<ticket>-<slug>` here, not the default thk shape — pass that prefix in branchName."
  - "PR descriptions need a `## Rollback` section by team convention; ensure draft-pr-description includes one even if the plan does not."
  - "When tagging the Linear assigner on a Draft PR, use the @-mention shape `@first.last` not `@firstlast` — the team has standardized on dotted handles."'
    ;;
  grand-maester)
    title="Grand Maester"
    specialty="correctness scholar — root-cause investigation, DB lookups, code-history reading, plan-history review"
    examples='  - "Before any user-scoped query, the schema requires a `tenant_id` predicate — the Grand Maester must include that in every PlanetScale lookup or the result will leak across tenants."
  - "When investigating a regression touching billing, check `git log --follow src/billing/legacy.ts` first — the file moved twice and recent blame is misleading."
  - "Grounding by historical incident: link to the Notion postmortem `Incident-NNN` when a finding mirrors a known prior bug."'
    ;;
  master-of-laws)
    title="Master of Laws"
    specialty="rules + verification — TypeScript, linters, tests, documented business rules"
    examples='  - "Verification on this repo includes a custom `pnpm run check:i18n` step beyond tsc + build — declare it in policies.json verification.extra_checks if not already there."
  - "Pre-existing tsc errors in `src/legacy/*` are tolerated; new ones anywhere else are blockers."
  - "Business rule: every public mutation API must have a corresponding integration test — Master of Laws should flag a missing one as a CHANGES_REQUESTED finding, not a nit."'
    ;;
  lord-commander)
    title="Lord Commander"
    specialty="adversarial security review — six lenses (injection, authz, race, exposure, supply-chain, DoS)"
    examples='  - "This codebase uses cookie-based sessions; any new `fetch` from the browser must include `credentials: \"same-origin\"` or the request is unauthenticated. Flag missing credentials as an authz issue."
  - "PII columns in this app: `users.email`, `users.phone`, `addresses.*`, `payments.cc_last4`. Lord Commander should flag any logging or response shape that emits these unredacted."
  - "We treat any shell-out from server code as a critical-severity finding by default; the project policy forbids spawning subprocesses outside the `jobs/` worker subsystem."'
    ;;
  master-of-coin)
    title="Master of Coin"
    specialty="effort + scope tracker (advisory only — never blocks)"
    examples='  - "Tickets touching the billing module reliably under-estimate by 2x — bake a multiplier into estimate-effort for any plan that edits `src/billing/`."
  - "Carve-out preference: this team prefers many small follow-up tickets over a single bundled refactor. When draft-techdebt-ticket runs, lean toward narrower scopes."
  - "Scope-check signal: a diff that grows past 8 changed files mid-execute on a non-refactor ticket usually means the plan was wrong. Recommend pause + plan revision rather than push-through."'
    ;;
  counselor)
    title="Counselor"
    specialty="final-pass external oversight (foreign expert, not a council member)"
    examples='  - "When reviewing a diff, this team values a brief verdict — one paragraph max, no executive summary. Long reviews get ignored in practice."
  - "Counselor on this repo should pay extra attention to N+1 query patterns; the ORM in use makes them easy to introduce silently."
  - "Style this team has explicitly rejected: `???` placeholder syntax in TypeScript signatures. Flag any `???` even if it tsc-checks."'
    ;;
  *)
    echo "write-agent-placeholder: unknown member '$member'" >&2
    exit 1
    ;;
esac

cat > "$target" <<EOF
<!--
Project-specific instructions for the ${title}.

This agent is your ${specialty}. It reads this file at the start of every
dispatch on this repo. If the file contains nothing beyond this placeholder
comment, the agent uses its built-in defaults.

To extend the agent's behavior on this repo, write your guidance below the
comment block — plain markdown, freeform. Examples of what fits here:

${examples}

This file is committed and team-shared (gitignore exception in
\`<repo>/.gitignore\`). Edit freely; thk never overwrites it.
-->
EOF

echo "write-agent-placeholder: wrote ${target}" >&2
