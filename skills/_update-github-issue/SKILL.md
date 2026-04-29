---
name: _update-github-issue
description: Edit an existing GitHub issue's body — used to push a revised `plan.md`, new reviewer artifacts, and any freshly-captured evidence back to the issue so GitHub's revision history becomes the audit log. Rebundles the FULL `contextDir/` (not just screenshots) inside the assets worktree, creates a new commit chained on top of the previous bundle commit, fast-forwards `refs/thk/<ticket>`, and regenerates the issue body using the new commit SHA. Keeps the body's top-level structure stable (plan verbatim → primary ticket inline → attached evidence) so GitHub's diff view shows clean revisions.
---

# Update GitHub Issue

Sibling of `publish-plan-to-github`. `publish` creates the issue; `update` edits it. They must produce the same body shape, so a reader sees clean diffs in GitHub's edit history rather than structural churn.

## Inputs

```
{
  workdir:        "<abs — code worktree, used only for `gh` repo context>",
  assetsWorkdir:  "<abs — the assets worktree at <sessionPath>/assets-worktree>",
  assetsRef:      "refs/thk/<TICKET-CODE>",
  issueUrl:       "<https://github.com/.../issues/N>",
  planPath:       "<abs>",
  contextDir:     "<abs>",
  runnerProfile?: "<runtime profile name — overrides the marker. Defaults to the value parsed from the existing issue body.>",
  meeting?:       "yes | no   — set on the first update after Step 3 fires; preserved verbatim on subsequent updates."
}
```

## Output

```
{
  issueUrl:        "<url>",
  issueNumber:     <n>,
  updatedAt:       "<ISO 8601>",
  attachmentDelta: <int>,       // number of files changed in this new commit
  assetsRef:       "refs/thk/<TICKET-CODE>",
  assetsSha:       "<40-char SHA of the new commit>",
  notes?:          string
}
```

## Procedure

### 1. Sanity checks

- `test -f <planPath>` — abort if missing.
- `test -d <contextDir>` — abort if missing.
- `test -d <assetsWorkdir>` — abort if missing.
- `gh auth status` — abort if not authenticated.
- Extract issue number from `issueUrl` — abort if the URL is malformed.

On any failure, return `{ error: "<reason>" }`.

### 2. Derive session-id

Same rule as `publish-plan-to-github`: second-to-last segment of `<contextDir>` (e.g. `<targetRepo>/.thk/sessions/<session-id>/context` → `<session-id>`). Fall back to a slug if the path doesn't match that shape.

### 3. Sync the assets worktree with origin's ref tip

The assets worktree's local branch may or may not match origin's `<assetsRef>` (e.g. a resumed session on a fresh machine). Fast-forward it before committing so we chain on top of the latest bundle commit, not a stale one:

```bash
cd <assetsWorkdir>
git fetch origin "<assetsRef>:<assetsRef>" 2>/dev/null || true
if git rev-parse --verify --quiet "<assetsRef>" >/dev/null; then
  git reset --hard "<assetsRef>"
fi
```

`git reset --hard` here is safe: the assets worktree is a scratch space, any local uncommitted content would be stale. If the ref doesn't exist yet (first-time update on a ref that was created by publish but then lost locally), proceed from the current HEAD.

### 4. Rebundle the FULL context folder + session log

Mirror `publish-plan-to-github`: copy every file under `<contextDir>/` (excluding `outcome.md`) into `.github/thk-assets/<session-id>/context/`, AND copy the three session-metadata peers (log, progress, runtime-profile) so the bundle carries the latest state for resume + rehydration:

```bash
cd <assetsWorkdir>
cp -R <contextDir>/. .github/thk-assets/<session-id>/context/
rm -f .github/thk-assets/<session-id>/context/outcome.md
session_root="$(dirname "$contextDir")"
[ -f "$session_root/log.md" ]              && cp "$session_root/log.md"              .github/thk-assets/<session-id>/session-log.md
[ -f "$session_root/progress.md" ]         && cp "$session_root/progress.md"         .github/thk-assets/<session-id>/session-progress.md
[ -f "$session_root/runtime-profile.json" ] && cp "$session_root/runtime-profile.json" .github/thk-assets/<session-id>/session-runtime-profile.json
git add .github/thk-assets/<session-id>/
```

Updating these on every push means `_thk/SKILL.md` Step 1.5's rehydration path reads the most recent `progress.md` from the bundle — not a stale snapshot from the initial publish.

- Stage explicit path only; never `git add .`.
- If nothing changed: `git diff --cached --quiet` returns 0 → skip commit/push, use the current ref-tip SHA as `assetsSha`, set `attachmentDelta: 0`. The issue body still gets regenerated because the caller may have edited `plan.md`.
- Otherwise: commit with message `chore(thk): update context bundle for <TICKET-CODE>`, then push to the custom ref:

```bash
git commit -m "chore(thk): update context bundle for <TICKET-CODE>"
git push origin "HEAD:<assetsRef>"
assetsSha="$(git rev-parse HEAD)"
attachmentDelta="$(git show --stat HEAD | grep -c ' | ')"
```

The push is a fast-forward because we reset to the ref's tip in step 3 before committing. If GitHub rejects it as non-fast-forward, someone else pushed to the ref between step 3 and here — refetch, reset, and retry once. If it fails again, return `{ error: "..." }`.

**Privacy pass.** Same as publish — scan bundled markdown for secret markers; surface a warning in `notes`, do not block.

### 5. Recompose the issue body

Same three-section structure as the initial publish:

1. **Plan** — `planPath` verbatim.
2. **Primary ticket** — `<contextDir>/linear/<TICKET-CODE>.md` inlined inside a `<details>` block (the file path is `linear/` because the Linear MCP is the current capture; future sources land in peer folders).
3. **Attached evidence** — preceded by the hidden ref marker, and starting with the **📜 Session log** link. Then the regenerated index of every bundled file (captured tickets, Jam artifacts with screenshots, Figma artifacts with screenshots, PlanetScale captures, reviewer markdown files under `plan-reviews/round-1/`, `plan-reviews/round-2/`, and `plan-reviews/round-3/`, analyst docs).

**URL format — non-negotiable.** Same rule as `publish-plan-to-github`: every link uses the **commit SHA** of this update's commit, not a ref name:

- `https://github.com/<owner>/<repo>/blob/<assetsSha>/.github/thk-assets/<session-id>/<path>`
- `https://github.com/<owner>/<repo>/raw/<assetsSha>/.github/thk-assets/<session-id>/<path>` (public repos only, for inline images)

Leading-slash repo-relative paths are not URLs — structural failure. For private repos, render screenshots as markdown links (not `![]()` embeds) because GitHub's camo proxy cannot fetch them.

Run `gh repo view <owner>/<repo> --json visibility --jq .visibility` once to know which mode to use.

**Hidden markers + fetch footer — carry them over from publish.** The body must contain three marker comments before the "Attached evidence" heading, plus the "To browse assets locally" fetch snippet inside the evidence section's preamble:

- `<!-- thk-assets-ref: <assetsRef> -->` — required from publish onward.
- `<!-- thk-runner-profile: <runnerProfile> -->` — required from publish onward.
- `<!-- thk-meeting: yes | no -->` — set by the *first* `update-github-issue` call after the Hand's Step 3 meeting decision. May be absent if Step 3 hasn't run yet; once present, preserve verbatim on subsequent updates unless the caller passes a new value.

When invoked without these inputs, parse them out of the existing issue body via `gh issue view <issueNumber> --json body --jq .body` and write them back unchanged. The caller can override by passing `runnerProfile`, `meeting` ("yes"/"no") explicitly.

If reviewer files exist under `<contextDir>/plan-reviews/`, render them under a dedicated **Council deliberation** section, split by phase. Paths are under `<BLOB>/context/plan-reviews/`:

```markdown
### Council deliberation

**Plan phase — Round 1** — four profiled member reviews (paths: `plan-reviews/round-1-plan/<slug>.md`):
- [Grand Maester](<url>) — <1-line summary>
- [Master of Laws](<url>) — <1-line summary>
- [Lord Commander](<url>) — <1-line summary>
- [Master of Coin](<url>) — <1-line summary>

**Plan phase — Round 2** — Counselor oversight (paths: `plan-reviews/round-2-plan/*.md`):
- [Counselor](<url>) — <1-line summary>

**Diff phase — Round 1** — four profiled member reviews of the executed diff (paths: `plan-reviews/round-1-diff/<slug>.md`):
- [Grand Maester](<url>) — correctness + edge cases
- [Master of Laws](<url>) — rules + verification
- [Lord Commander](<url>) — adversarial security read
- [Master of Coin](<url>) — scope drift

**Diff phase — Round 2** — Counselor oversight on the diff (paths: `plan-reviews/round-2-diff/*.md`):
- [Counselor](<url>) — <1-line summary>

**Hand's synthesis** — single audit trail across both phases (path: `plan-reviews/hand-decision.md`):
- [hand-decision.md](<url>) — Sections 1–2 = plan-phase verdicts; Sections 3–4 = diff-phase verdicts.

**No-meeting flow** — single Counselor pre-PR review (path: `plan-reviews/counselor-pre-pr.md`):
- [Counselor pre-PR review](<url>) — <1-line summary>
```

Omit a section if no files are present yet (e.g., a meeting-flow run after plan-phase completes has only the plan-phase rounds; diff-phase sections appear after the Hand executes and Step 6b runs). The no-meeting `counselor-pre-pr.md` and the meeting `round-1-diff/`/`round-2-diff/` are mutually exclusive — only one path's artifacts will exist per ticket.

Body-size cap: 65,000 characters. If the recomposed body exceeds it, the primary-ticket inline `<details>` block is the usual culprit — replace with a link. Never truncate the plan.

Write the body to `/tmp/thk-issue-<session-id>.md`.

### 6. Push the edit

```bash
cd <workdir>
gh issue edit <issueNumber> --body-file /tmp/thk-issue-<session-id>.md
```

### 7. Verify

Same rule as `publish-plan-to-github` step 6 — verify the URLs that actually appear in the **issue body**, not just files-on-disk.

1. `gh issue view <issueNumber> --json body --jq .body`.
2. Extract every URL inside markdown link / image syntax. Any value that does not start with `https://` is a structural failure → return `{ error: "issue body contains non-URL link: <path>" }`.
3. Confirm the hidden markers are present:
   - `<!-- thk-assets-ref: ... -->` (always required) — return `{ error: "issue body missing assets ref marker" }` if not.
   - `<!-- thk-runner-profile: ... -->` (always required) — return `{ error: "issue body missing runner profile marker" }` if not.
   - `<!-- thk-meeting: yes | no -->` (required iff Step 3 has run) — only enforce when the caller passed `meeting`; otherwise tolerate absence.
4. Verify `<assetsSha>` is reachable on origin: `gh api "/repos/<owner>/<repo>/commits/<assetsSha>"` → HTTP 200.
5. Pick 1–2 newly-committed asset URLs (newest reviewer markdown, newest screenshot if any). For private repos verify with `gh api "/repos/<owner>/<repo>/contents/<path>?ref=<assetsSha>"`. For public repos `curl -sI`. A 404 breaks the self-contained contract → return `{ error: "asset URL unreachable: <url>" }`.

### 8. Return

```
{ issueUrl, issueNumber, updatedAt, attachmentDelta, assetsRef, assetsSha, notes? }
```

## Rules

- **Same body structure as `publish-plan-to-github`.** If you change one, change both — divergence ruins the GitHub edit-history readability.
- **Plan verbatim first.** Never reformat the plan when composing the body; the plan file is the source of truth.
- **Bundle everything, always.** New reviewer markdown, new PlanetScale captures, new Jam screenshots — whatever appeared in `<contextDir>/` since the last publish/update gets bundled.
- **Commits happen in the assets worktree, never the code worktree.** `cd <assetsWorkdir>` for every git operation.
- **Push target is the custom ref.** `git push origin HEAD:<assetsRef>`. Fast-forward only; on reject, refetch/reset and retry once.
- **URLs use the new commit SHA.** Each update regenerates every link so the current issue version resolves against the current commit. Old issue revisions in GitHub's edit history keep their own SHAs, which are still reachable through the ref's commit chain.
- **Stage explicitly.** Only the `.github/thk-assets/<session-id>/` subtree. Never `git add .` / `-A`.
- **Title is immutable.** Never alter the issue title here — only `publish` sets it.
- **Atomic failure.** If any step after staging fails, `git reset HEAD` in the assets worktree and return `{ error: "..." }`. Do not leave the repo half-committed.
- Pass content to `gh` with real newlines, not `\n` escapes.
