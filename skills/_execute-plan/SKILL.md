---
name: _execute-plan
description: The Hand executes the finalized plan — reads the spec from `<contextDir>/plan.md`, makes the edits (Edit/Write/Bash), updates tests per the plan's Tests section, dispatches Master of Laws for verification, and fixes-and-retries when verification fails. Single-agent execution by design — the plan is locked, this is pure implementation, parallel agents would just create merge-conflict surface and re-derive the holistic mental model the Hand already has from drafting the plan.
---

# Execute the Plan

The plan in `<contextDir>/plan.md` is the spec. This skill turns it into a working tree diff that survives the project's verification gauntlet (whatever `_run-verification` infers from `package.json` + lockfile, or whatever overrides the project declares in `<workdir>/.thk/policies.json`). The Hand drives — single agent, single mental model, sequential edits.

## Inputs

```
{
  workdir:        "<abs — code worktree where edits land>",
  contextDir:     "<abs — session context>",
  planPath:       "<abs — context/plan.md>",
  ticketCode:     "<ENG-10105>",
  runtimeProfile: <resolved profile object>,
  maxIterations?: <int — default 3 — verification fix-and-retry cap>
}
```

## Output

```
{
  success:             boolean,        // verification green at the end
  filesChanged:        string[],       // every file the Hand touched (relative to workdir)
  iterations:          <int>,          // how many verification rounds were needed
  verificationOutcome: "green" | "failed-after-retries" | "skipped",
  notes?:              string          // anything the next step needs to know
}
```

## Why one agent, not a swarm

Code is deeply chained — a signature change in one file implies call sites, shared types, and test updates everywhere. Splitting that across parallel agents creates merge-conflict surface and forces a synthesis step that itself needs the whole mental model. The Hand drafted the plan; the Hand's context already carries the relationships between files, the assumptions baked into the plan, and the open questions. Spawning fresh Opus instances throws all of that away to re-derive what the Hand already knows.

The exception is genuinely embarrassingly parallel work — a mechanical rename across disjoint files, a doc-only sweep. The Hand can fan out then. Default is solo.

## Procedure

### 1. Re-read the plan + key context

Re-read `<planPath>` from disk — the plan may have been revised by `convene-meeting` after Step 3a/3b/3d, so don't trust an in-memory copy from earlier in the session.

For each file listed in the plan's "Files to modify" / "Files to delete" tables, `Read` it before editing. Sanity-check that the file matches the plan's assumed shape — if a function the plan references has moved or been renamed, surface the divergence in `notes` and adapt rather than blindly edit.

If the plan references specific Linear / Jam / Figma evidence (e.g. "see jam/<id>/transcript.md"), `Read` those too. The plan should be self-sufficient, but evidence pointers exist for a reason.

### 2. Apply the edits

Walk the plan's tables in order. For each entry:

- **Files to delete** — `Bash("rm <path>")`. Stage the deletion explicitly later via `commit-changes`.
- **Files to add** — `Write(<path>, <content>)`. Match neighboring file conventions (header, imports, naming).
- **Files to modify** — `Edit(<path>, ...)`. Multiple edits per file are fine; do them sequentially in one logical chunk. If the same file is modified for multiple reasons in the plan, group the edits.

Every edit should be the minimum surgical change implied by the plan's Approach + Files tables. Don't refactor adjacent code, don't add comments the plan didn't call for, don't rename unrelated symbols. The plan has a "Intentional non-goals" section — respect it.

### 3. Update tests

Read the plan's "Tests" section. For each entry:

- **Test to add** — write the test file. Follow the repo's existing test conventions (look at sibling tests for shape).
- **Test to modify** — `Edit` the existing test.
- **Test to delete** — only if the plan explicitly says so.

If the plan's Tests section is empty (e.g. doc-only change, infra), skip this step but note `verificationOutcome: skipped` in the return envelope's `notes` field.

### 4. Verification round

Dispatch Master of Laws:

```
Agent(master-of-laws, prompt="action: run-verification. workdir: <workdir>.")
  → returns { approved, issues?, notes }
```

`run-verification` runs the project's install + type-check + build, with the exact commands inferred from the lockfile (`pnpm` / `yarn` / `npm` / `bun`) and `package.json` scripts — overridable via `<workdir>/.thk/policies.json`. Pre-existing type / build errors on the branch are acceptable; new ones introduced by the diff are blockers.

If `approved: true` → verification passed. Set `iterations`, `verificationOutcome: "green"`, return `success: true`.

If `approved: false` → read the `issues` / `notes` for the actual error output, then proceed to Step 5.

### 5. Fix-and-retry

For each blocking error:

- Type errors → `Read` the cited file:line, identify the cause (missing import, signature mismatch, unused variable, etc.), `Edit` the fix.
- Build errors → if the error is in code you wrote, fix it. If the error is in pre-existing code, surface the divergence in `notes` and bail (status `verificationOutcome: "failed-after-retries"`).
- Test failures → re-read the test, the implementation, and the expected behavior in the plan. If the test reveals the implementation is wrong, fix the implementation. If the test itself is wrong, fix the test.

After fixing, return to Step 4 for another verification round. Cap at `maxIterations` (default 3). If the cap is reached and verification is still red, return `success: false`, `verificationOutcome: "failed-after-retries"`, and put the last verification's error summary in `notes`.

### 6. Return

```
{
  success: true,
  filesChanged: ["<rel-path-1>", "<rel-path-2>", ...],
  iterations: <count>,
  verificationOutcome: "green",
  notes?: "..."   // e.g. "test section was empty; verification covered tsc + build only"
}
```

## Logging

Log each step via `${CLAUDE_PLUGIN_ROOT}/scripts/log.sh`:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand step-start "execute-plan: <ticketCode>"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand decision "edits applied to <N> files"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand dispatch "master-of-laws action=run-verification (iter=<N>)"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> hand step-done "execute-plan: green after <N> iterations"
```

If verification fails after the retry cap, log it as `error` with the last verification message.

## Rules

- **Single agent.** The Hand executes alone. No `Agent(...)` dispatches except to `master-of-laws` for verification.
- **Stay in the worktree.** Every edit lands in `<workdir>`. Never touch `<assetsWorkdir>` or anything under `.github/thk-assets/` here — those belong to the publish/update flow.
- **Honor the plan's non-goals.** If the plan says "do not refactor X", don't touch X even if you see something nearby that would benefit.
- **Do not commit.** This skill ends with a clean working tree of edits. The Hand's next step (Step 6 of `thk`) is the commit + PR draft via Master of Ships.
- **Do not push.** Pushing happens in `push-and-open-pr` after Grand Maester drafts the PR description.
- **No `--no-verify`, no `git add .`.** Both rules continue to hold — they live in `commit-changes` / `push-and-open-pr` and apply to those skills' callers, but execute-plan must not work around them.
- **Iteration cap is a real cap.** If you hit `maxIterations` and verification is still red, return `success: false`. Do not silently keep retrying.
- **Surface deviations.** If the plan's assumed file shape no longer matches reality (the file was renamed, deleted, refactored after the plan was drafted), don't paper over it — note it in `notes` so the Hand can decide whether to revise the plan or proceed.
