---
name: _revisit-pr
description: Revisit a Draft PR after external review feedback has landed (CodeRabbit, human reviewers, other bots). Self-contained — handles cold rehydration from Linear → GitHub issue when nothing local exists for the ticket. Pulls PR comments, triages findings, applies accepted fixes, re-runs verification, replies on threads, pushes back, and re-bundles the session into the GitHub issue. The Hand drives implementation alone; escalates to a diff-phase meeting only when the volume or severity warrants it.
---

# Revisit a PR

A Draft PR has been open long enough for external reviewers to weigh in — typically CodeRabbit, sometimes humans, sometimes other bots. This skill closes the loop: collect the feedback, decide what's worth addressing, apply fixes, push, and update the GitHub issue.

This skill is **self-contained** — it can be invoked by the Hand (Step 8), by a `/schedule`-spawned background agent, or directly via `/thk revisit <TICKET>`. It detects whether the local session is warm (worktree present) or cold (nothing local) and rehydrates as needed.

## Inputs

```
{
  ticketCode:     "<ENG-10105>",
  workdir?:       "<abs — code worktree if warm; absent or stale if cold>",
  contextDir?:    "<abs — session context if warm; absent if cold>",
  sessionRoot?:   "<abs — <repo>/.claude/.thk/sessions/<id>/ if warm>",
  targetRepo:     "<abs — the repo root, always known>",
  runtimeProfile: <resolved profile object — re-resolved by the Hand at Step 0>,
  prUrl?:         "<https://github.com/owner/repo/pull/N — preferred; if absent, derived from ticket links>",
  reviewBots?:    ["coderabbitai", ...],   // overridable per-call; default reads policies.json
  meetingThreshold?: <int — accepted-finding count that escalates to a diff meeting; default 3>
}
```

## Output

```
{
  success:           boolean,
  rehydrated:        boolean,             // true if we recovered from a cold start
  round:             <int>,                // 1 for first revisit, increments per re-run
  findings: {
    total:           <int>,
    by_source:       { coderabbitai: <int>, humans: <int>, other_bots: <int> },
    accepted:        <int>,
    deferred:        <int>,
    declined:        <int>,
    stale_skipped:   <int>                // findings against an older SHA
  },
  meetingEscalated:  boolean,             // true if diff-phase meeting ran
  verificationOutcome: "green" | "failed-after-retries" | "skipped",
  newCommits:        ["<sha>", ...],       // appended to the PR branch
  headShaAfter:      "<40-char SHA>",
  prCommentUrl:      "<url of the summary comment>",
  notes?:            string
}
```

## Procedure

### 0a. Read (or auto-bootstrap) `revisit` policies

Before pulling reviews, resolve two values from `<targetRepo>/.claude/.thk/policies.json`:

```json
{
  "revisit": {
    "review_bots":               ["coderabbitai"],
    "meeting_escalation_threshold": 3,
    "decline_styles": []
  }
}
```

Resolution order:

- If the caller passed `reviewBots` and/or `meetingThreshold` explicitly → use those (per-call override always wins).
- Else if `policies.json` has the `revisit` block → use those values.
- Else → fall back to the defaults above.

**Auto-bootstrap on first run.** If `policies.json` exists but has no `revisit` block, merge the default block in (preserve any other top-level keys). If `policies.json` doesn't exist, create it with `_meta` + `revisit` blocks. Log a stderr notice: `_revisit-pr: bootstrapped revisit policy block in <path>. Review and commit.` This mirrors the auto-drop pattern in `_capture-planetscale` and `_run-verification` — same file, different top-level key.

`decline_styles` is a future hook for project-specific style preferences (e.g., `["camelCase-vs-snake_case"]`) that the Hand auto-declines without re-debating per round. Empty array on bootstrap; teams populate it as patterns emerge.

### 0b. Ensure rehydrated (cold-start support)

If `workdir` and `contextDir` are both provided and exist on disk, we're **warm** — skip to Step 1.

Otherwise we're **cold**. This is the case when `/thk revisit <TICKET>` is invoked from a fresh checkout, a different machine, or after `_cleanup-session` has run. Rehydrate in three sub-steps:

**0a. Locate prior context via Linear.** Dispatch Master of Whisperers:

```
Agent(master-of-whisperers, prompt="action: capture-linear. ticketCode: <code>. workdir: <targetRepo>. contextDir: <will-be-created>.")
  → returns { issueData, links: [...], comments: [...] }
```

The capture writes `<targetRepo>/.claude/.thk/sessions/<new-or-reused-id>/context/linear/<code>/` and returns the parsed issue. Inspect `links[]` for two pointers:

- A GitHub **issue** under the configured `<owner>/<repo>` whose body contains the `<!-- thk-runner-profile -->` marker (the durable thk session log)
- A GitHub **pull request** under the same repo (the Draft PR)

If neither exists → return `{ success: false, notes: "no prior thk run for ticket <code> — run /thk <TICKET> first" }`. We do not bootstrap a fresh run from `revisit`; that's a different entry point.

**0b. Pull the bundle from the GitHub issue.** Dispatch Master of Ships:

```
Agent(master-of-ships, prompt="action: rehydrate-from-issue. ticketCode: <code>. issueUrl: <gh-issue-url>. targetRepo: <abs>.")
  → returns { sessionRoot, contextDir, workdir, assetsRef, priorRuntimeProfile, headBranch, headSha }
```

This action (Master of Ships will own its `_rehydrate-from-issue` skill — see [Plumbing details](#plumbing-rehydrate)) does:

1. Parse the issue body for `<!-- thk-assets-ref -->` and `<!-- thk-runner-profile -->` markers
2. `git fetch origin <assetsRef>` → check out the orphan asset commit into `<targetRepo>/.claude/.thk/sessions/<reused-id>/assets-worktree/`
3. Copy `session-log.md`, `session-progress.md`, `session-runtime-profile.json`, and `context/` out of the asset commit into the new session folder
4. From `runtime-profile.json` read `prUrl` and the head branch + SHA
5. `git fetch origin <headBranch>` then `git worktree add <sessionRoot>/worktree origin/<headBranch>` — the worktree is now at the PR head, not main
6. Return absolute paths so subsequent steps work identically to a warm session

**0c. Reconcile profile.** The rehydrated `priorRuntimeProfile` may reference a runner the current host doesn't have (e.g., the original session ran on Codex, this revisit is on Claude only). Compare with the freshly resolved `runtimeProfile`:

- If the role runners are compatible → use `runtimeProfile` (current host's choices)
- If incompatible → degrade gracefully (e.g., Counselor role flips from `codex-cli` to `claude-code` if Codex is unavailable) and add a note to `notes` documenting the divergence

Set `rehydrated: true` for the return envelope. Continue to Step 1.

### 1. Pull PR feedback

```bash
gh pr view <prUrl> --json number,headRefName,headRefOid,baseRefName,mergeable,reviews,comments,state
```

Capture three things:

- **Current head SHA** (`headRefOid`) — used to discard stale findings
- **Reviews** (`reviews[]`) — top-level review submissions with `state: APPROVED | CHANGES_REQUESTED | COMMENTED` and a `body`
- **Comments** (`comments[]`) — issue-level comments + per-thread `comments` returned via `gh api repos/<owner>/<repo>/pulls/<n>/comments` (per-line review comments are not in the `--json comments` output; fetch separately)

Combine into a single list of "findings" with shape:

```
{ id, source: "coderabbit"|"human"|"bot-other", author, file?, line?, body, sha_at_comment, is_stale }
```

Mark `is_stale: true` when `sha_at_comment !== current head SHA`. Stale findings are skipped (the code they referenced may already be different); count them in `stale_skipped` and move on.

Filter `source` by author login:

- `coderabbitai` (or any login in `reviewBots`) → `source: "coderabbit"`
- A `User` (not `Bot`) account → `source: "human"`
- Any other bot → `source: "bot-other"`

If the only findings are praise or `state: APPROVED` with no actionable bullets → return early with `findings.total: 0`, success, no commits, no comment posted. Don't manufacture work.

### 2. Triage

Write `<contextDir>/pr-reviews/round-<N>/triage.md` (next round number — read existing folders to determine N). One row per non-stale finding:

```markdown
| ID | Source | File:Line | Severity | Verdict | Reasoning |
|---|---|---|---|---|---|
| 1  | coderabbit | src/api/auth.ts:42 | minor | accept | Real null-check gap; one-line fix. |
| 2  | coderabbit | src/api/auth.ts:91 | nit | decline | Style preference, conflicts with the file's existing convention. |
| 3  | human (alice) | src/lib/cache.ts:18 | major | accept | Race condition I missed; needs lock. |
| 4  | coderabbit | README.md:1 | nit | defer | Doc tweak, separate ticket. |
```

Verdict rules:

- **accept** — actionable, in scope of the original ticket, fix is straightforward
- **defer** — actionable but should be its own ticket (out of scope, refactor, separate concern). Generates a tech-debt ticket draft via Master of Coin (`draft-techdebt-ticket`)
- **decline** — not actionable. Includes: style nitpicks that conflict with repo conventions, false positives (CodeRabbit hallucinated a problem), suggestions that violate the plan's "Intentional non-goals"

The Hand triages alone for routine cases. **Reach for Grand Maester** when a finding asks "is this correct?" and the Hand isn't sure (`Skill("_review-correctness", ...)`). **Reach for Lord Commander** when a finding flags a security concern and the Hand wants a second read (`Agent(lord-commander, "action: red-team-review ...")`).

### 3. Escalate to a diff meeting? (rare)

Count `accepted` findings. Escalate to a full diff-phase meeting **only** if:

- `accepted >= meetingThreshold` (default 3), **OR**
- Any accepted finding has `severity: critical`, **OR**
- The Lord Commander or Grand Maester ad-hoc consult in Step 2 returned non-empty `issues[]`

If escalating, dispatch:

```
Skill("_convene-meeting", {
  phase: "diff",
  workdir, contextDir, planPath: "<contextDir>/plan.md",
  ticketCode, issueUrl, runtimeProfile,
  baseBranch  // PR's baseRefName from Step 1
})
  → returns { rounds, diffRevised, finalAssetsSha, ... }
```

The diff meeting absorbs the implementation step too — Council members review, the Hand fixes, Counselor closes. If meeting runs, set `meetingEscalated: true` and skip Steps 4–5. Continue from Step 6 (push) using the meeting's outcome.

If not escalating, continue to Step 4.

### 4. Implement accepted findings

For each `accept` row, in order:

- Read the cited file:line
- Apply the fix (Edit/Write/Bash) — minimum surgical change, same posture as `_execute-plan`
- One logical commit per finding (or per cluster of findings on the same file with the same theme), with commit message format:
  ```
  fix: <short summary>

  Addresses <source>'s comment on <file>:<line> in PR #<n>.
  ```

Do not amend or rewrite existing commits — Draft PRs are append-only by convention. The reviewer needs to see what was done in response.

For each `defer` row, draft a tech-debt ticket via Master of Coin:

```
Agent(master-of-coin, prompt="action: draft-techdebt-ticket. parentTicketCode: <code>. carveoutDescription: <one-line + finding body>. workdir: <workdir>.")
  → returns { artifacts: { ticketBodyPath } }
```

Collect the ticket bodies — they get linked from the PR comment in Step 6.

### 5. Re-run verification

Dispatch Master of Laws:

```
Agent(master-of-laws, prompt="action: run-verification. workdir: <workdir>.")
  → returns { approved, issues?, notes }
```

If `approved: false`, fix per the Step-5 logic in `_execute-plan` (cap at 3 iterations). If verification stays red after the cap → return `{ success: false, verificationOutcome: "failed-after-retries", notes: "<last error>" }` without pushing. The Hand surfaces the failure to the human.

### 6. Reply on the PR + push

Dispatch Master of Ships **twice**:

**6a. Push commits.**

```
Agent(master-of-ships, prompt="action: push-revisit-commits. workdir: <workdir>. branch: <headRefName>.")
```

Plain `git push` to the same branch. No force-push. Capture the new head SHA.

**6b. Post the summary comment + per-thread replies.**

```
Agent(master-of-ships, prompt="action: post-revisit-summary. prUrl: <url>. round: <N>. triage: <path-to-triage.md>. deferredTickets: [...].")
```

Posts:

- One issue-level comment summarizing this round: "Revisit round <N>: addressed <X>, deferred <Y>, declined <Z>. New head: <sha>. [triage](link to bundled file)."
- One reply per `accept` row: `> Resolved by <commit-sha>.`
- One reply per `defer` row: `> Deferred to <techdebt-ticket-url> (out of scope for this PR).`
- One reply per `decline` row: `> Declined: <one-line reasoning>.`

Returns `{ commentUrl, repliesPosted }`.

### 7. Re-bundle the session

The session now has new artifacts (`pr-reviews/round-<N>/`, possibly new commits, possibly new tech-debt ticket bodies). Push them to the GitHub issue:

```
Agent(master-of-ships, prompt="action: update-github-issue. issueUrl: <url>. contextDir: <contextDir>. sessionRoot: <sessionRoot>.")
```

This bundles `session-log.md`, `session-progress.md`, `session-runtime-profile.json`, and `context/` (now including the new `pr-reviews/round-<N>/` folder) into the orphan ref and updates the issue body with new attachment links.

### 8. Return

```
{
  success: true,
  rehydrated: <bool>,
  round: <N>,
  findings: { ... },
  meetingEscalated: <bool>,
  verificationOutcome: "green",
  newCommits: ["<sha-1>", "<sha-2>", ...],
  headShaAfter: "<sha>",
  prCommentUrl: "<url>",
  notes?: "..."
}
```

## Logging

Every major step writes a log entry; council dispatches use the three-entry pattern (skill-invoke + dispatch-detail + skill-return) per their agent files.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand step-start "revisit-pr round=<N> ticket=<code>"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand decision "regime=<warm|cold>"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand decision "findings: total=<n> coderabbit=<n> human=<n> stale=<n>"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand decision "triage: accept=<n> defer=<n> decline=<n>"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand decision "meeting-escalated=<bool> threshold=<n>"
# ... per-finding edits, dispatched via the standard hand dispatch-detail pattern ...
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand step-done "revisit-pr round=<N>: <outcome>"
```

When rehydrating, log the cold-start sub-steps explicitly so a follow-up reader can trace which bundle commit was the source.

## <a name="plumbing-rehydrate"></a>Plumbing detail — Master of Ships' `rehydrate-from-issue`

This action is new — it complements the existing `update-github-issue` (push side). It needs to be added to the Master of Ships agent file and a corresponding `_rehydrate-from-issue` skill folder. The skill's contract:

```
Inputs:  { ticketCode, issueUrl, targetRepo }
Outputs: { sessionRoot, contextDir, workdir, assetsRef, priorRuntimeProfile, headBranch, headSha }
```

Mechanical steps it performs:

1. `gh issue view <issueUrl> --json body` → extract `<!-- thk-assets-ref -->` and `<!-- thk-runner-profile -->` markers
2. `git -C <targetRepo> fetch origin <assetsRef>:<assetsRef>` to pull the orphan ref
3. Mint a new session ID (`<ts>_<ticketCode>_revisit-<round>` by convention) at `<targetRepo>/.claude/.thk/sessions/<id>/`
4. `git worktree add <sessionRoot>/assets-worktree <assetsRef>` and copy `session-log.md`, `session-progress.md`, `session-runtime-profile.json`, and `context/` into `<sessionRoot>/`
5. Read `runtime-profile.json` for `prUrl` and the head branch
6. `git fetch origin <headBranch>` → `git worktree add <sessionRoot>/worktree origin/<headBranch>`
7. Return the absolute paths

This skill is invoked only from `_revisit-pr` Step 0b. Build it as a peer of `_publish-plan-to-github` and `_update-github-issue`.

## Rules

- **Self-contained.** The skill must work given just `{ ticketCode, targetRepo, runtimeProfile }` if the prior bundle exists on the issue. Cold rehydration is a first-class path, not an edge case.
- **Append-only.** No force-push, no commit amend. Reviewers need to see the response.
- **Stale findings stay skipped.** Don't try to "fix" against an old SHA — counted in `stale_skipped` and moved on.
- **Praise is not work.** If reviewers only commented `LGTM` or approved, return early with `findings.total: 0`. Don't post a no-op summary.
- **Verification is non-negotiable.** Same as `_execute-plan` — green or no push.
- **Defer is a real verdict.** A tech-debt ticket is the right answer for findings that aren't this PR's concern. Never silently decline scope-creep findings without offering a defer path.
- **Meeting escalation is rare.** Default-flow revisits should resolve in single-Hand mode. Only convene a diff meeting when severity or volume warrants it (threshold or critical or council ad-hoc flagged).
- **Counselor never runs ad-hoc here.** If a meeting is convened, Counselor closes (per `_convene-meeting`'s contract). Otherwise no Counselor — same audit-trail rule as elsewhere.
