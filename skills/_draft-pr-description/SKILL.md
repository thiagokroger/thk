---
name: _draft-pr-description
description: Grand Maester scholar action — read the plan + the actual `git diff` + the published GitHub issue + the source ticket, then compose a Draft PR's title and body that connects what was implemented to what was planned. **Persists** the title and body to `<contextDir>/pr-title.txt` and `<contextDir>/pr-body.md` so Master of Ships' `push-and-open-pr` can read them from disk — passing long bodies through agent context risks corruption when the dispatch happens later (e.g., after a 30-minute meeting). Returns `{ title, body, titlePath, bodyPath }`. Cites the issue and the ticket so reviewers land on the full context with one click.
---

# Draft PR Description

The plan is the chronicle of what was decided; the diff is the chronicle of what was done. The Grand Maester reads both, plus the originating ticket and the published GitHub issue, and writes the PR description that ties them together. Master of Ships then executes the actual `gh pr create --draft`.

## Inputs

```
{
  workdir:          "<abs — code worktree, used to read git diff>",
  contextDir:       "<abs — session context>",
  planPath:         "<abs — context/plan.md>",
  ticketCode:       "<ENG-10105>",
  issueUrl:         "<https://github.com/.../issues/N — published plan>",
  linearTicketUrl:  "<https://linear.app/.../ENG-10105>",
  baseBranch?:      "<base branch for the diff comparison — default: main>"
}
```

## Output

```
{
  title:     "<one-line PR title — matches repo convention>",
  body:      "<markdown PR body — described below>",
  titlePath: "<abs — <contextDir>/pr-title.txt>",
  bodyPath:  "<abs — <contextDir>/pr-body.md>"
}
```

The inline `title` / `body` fields are kept for callers that may want to inspect the values, but **`titlePath` / `bodyPath` are the canonical handoff** — `_push-and-open-pr` reads from those files and ignores the inline strings. Long bodies passed through agent context have been observed to corrupt on a 30+ minute gap between composition and dispatch (the Grand Maester might compose at T+0 and Master of Ships might run after a long meeting at T+55m, by which point the body has fallen out of the dispatching agent's working context). The file-based handoff bypasses agent context entirely.

## Procedure

### 1. Read the inputs

- `Read(planPath)` — full plan, top to bottom.
- `Read(<contextDir>/linear/<TICKET-CODE>.md)` — the originating ticket, for the Summary's framing.
- `Bash("cd <workdir> && git log --oneline -20")` — match the repo's commit-message tone (terse / verbose, prefix style, etc.).
- `Bash("cd <workdir> && git diff <baseBranch>...HEAD --stat")` — file-by-file diff summary.
- `Bash("cd <workdir> && git diff <baseBranch>...HEAD")` — full diff for the body's "What changed" mapping.

### 2. Compose the title

One line, under ~70 characters. Prefix with the ticket code if the repo's commits do (read `git log --oneline -20` and follow the convention). Use imperative mood — "fix X" / "add Y" / "refactor Z" — matching the plan's verb.

Examples (style depends on repo conventions):
- `ENG-10105: fix double-fetch on dashboard mount`
- `fix(dashboard): prevent double-fetch on mount (ENG-10105)`
- `Add retry-with-backoff to upload pipeline (ENG-10210)`

### 3. Compose the body

The body has six sections in this order. Use real newlines (not `\n` escapes). Skip the optional ones when there's nothing to say.

```markdown
## Summary

<2–3 sentences pulled from the plan's Summary, framed as "what this PR does and why" — not "what the bug was". Mention the user-visible effect.>

## Plan

The full plan (with bundled context — Linear thread, Jam recordings, Figma designs, Council reviews when present) lives on the GitHub issue:

- **Plan & context:** <issueUrl>
- **Source ticket:** <linearTicketUrl>

## What changed

<Map the actual diff back to the plan's "Files to modify / add / delete" tables. One bullet per logical change, not one per file. Reference file paths so reviewers can jump.>

- `<file/path>` — <one-line description of the change>
- `<file/path>` — <one-line description>
- ...

## Test plan

<Bulleted markdown checklist sourced from the plan's "Tests" section, plus anything actually exercised. Reviewers check these items off as they verify locally.>

- [ ] <test scenario 1>
- [ ] <test scenario 2>
- [ ] Verification gauntlet passes (whatever `_run-verification` resolved for this project — substitute the literal commands here, e.g. `pnpm tsc --noEmit && pnpm run build` or `npm run typecheck && npm run build` or `cargo check && cargo build`. Read them out of the run's logs.)

## Deviations from the plan

<Optional. Include only if the implementation diverged from the plan in a non-trivial way. Each deviation: what the plan said vs what the diff does, plus why. If the diff matches the plan, omit this section entirely.>

- **<topic>:** <plan said X, implementation does Y because Z.>

## Notes for review

<Optional. Anything the reviewer should look at carefully — a tricky invariant, a non-obvious choice, an open question. If the plan covered everything cleanly, omit this section.>
```

### 4. Sanity-check before returning

- Title ≤ 70 chars, no trailing period, imperative mood.
- Every URL in the body is a real `https://` URL — no leading-slash paths, no `<placeholder>` left unsubstituted.
- The "What changed" bullets actually reference paths that appear in `git diff --name-only`.
- The Test plan is a real checklist, not aspirational ("- [ ] manual test passes" is not enough — it should name what the reviewer should manually exercise).

If a sanity check fails, fix the body before returning. Don't ship a half-templated PR.

### 5. Persist to disk (mandatory — handoff is file-based)

Write the title and body to `<contextDir>/`:

```bash
printf '%s\n' "$TITLE" > "<contextDir>/pr-title.txt"
# For the body, write the markdown verbatim — no quoting, no escape conversion.
# Use a heredoc against an absolute path to avoid any agent-side substitution:
cat > "<contextDir>/pr-body.md" <<'PR_BODY_EOF'
<the full markdown body composed in step 3>
PR_BODY_EOF
```

Verify both files were written and are non-empty before returning:

```bash
[ -s "<contextDir>/pr-title.txt" ] || error "pr-title.txt failed to write"
[ -s "<contextDir>/pr-body.md"  ] || error "pr-body.md failed to write"
```

Body must be at least 100 bytes (a real PR body composed per Step 3 is always larger). If smaller, it's a sign the composition itself was truncated — error rather than persisting a degraded body.

### 6. Return

```
{
  title:     "<TITLE>",
  body:      "<BODY>",
  titlePath: "<contextDir>/pr-title.txt",
  bodyPath:  "<contextDir>/pr-body.md"
}
```

## Rules

- **Persists, never inlines.** The PR title and body are written to `<contextDir>/pr-title.txt` and `<contextDir>/pr-body.md`. `_push-and-open-pr` reads from those files. The handoff must not depend on the body surviving in agent context — gaps between this skill and PR open can be 30+ minutes (e.g., diff-phase meeting), and long markdown bodies have been observed to corrupt across that gap.
- **Read-only on the code side.** The Grand Maester does not write code, does not commit, does not push. He composes the description (and persists it to `<contextDir>/`); Master of Ships executes the PR open.
- **Cite the chronicle.** Always link the GitHub issue (the plan + bundled context) and the source ticket. Reviewers should land on the full context with one click.
- **Match repo tone.** Read `git log --oneline -20` first; copy the convention. Don't invent a new style.
- **No fluff sections.** Omit "Deviations" and "Notes for review" if there's genuinely nothing to say. Empty sections in PRs read as careless.
- **No Co-Authored-By line.** Same rule as `commit-changes` — the PR is authored by the user.
- **No emojis** unless the repo's existing PRs use them. Match what's already shipping.
- **Log the dispatch** via `${CLAUDE_PLUGIN_ROOT}/scripts/log.sh` per the Grand Maester's standard rules.
