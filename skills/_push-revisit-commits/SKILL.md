---
name: _push-revisit-commits
description: Push new revisit commits to an existing PR branch. Plain `git push` — never force, never amend, never rewrite history. Used by `_revisit-pr` Step 6a after the Hand has applied accepted findings as new commits on the worktree.
---

# Push Revisit Commits

Mechanical fast-forward push to an existing PR branch. Draft PRs are append-only by convention — reviewers need to see what was done in response to their feedback as discrete new commits.

## Inputs

```
{
  workdir:  "<abs — code worktree on the PR head branch>",
  branch:   "<branch name — must match the PR's headRefName>"
}
```

## Output

```
{
  approved:     true,
  artifacts: {
    pushed:        boolean,           // false if there were no new commits to push
    newCommits:    ["<sha>", ...],     // commits that were on local HEAD but not origin/<branch>
    headShaBefore: "<sha>",
    headShaAfter:  "<sha>"
  },
  notes?: string
}
```

## Procedure

### 1. Verify branch state

```bash
cd <workdir>
current_branch=$(git rev-parse --abbrev-ref HEAD)
[ "$current_branch" = "<branch>" ] || return error "worktree is on '$current_branch', expected '<branch>'"

git fetch origin "<branch>"
local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse "origin/<branch>")
```

If `local_sha == remote_sha` → return `{ approved: true, artifacts: { pushed: false, newCommits: [], headShaBefore: <sha>, headShaAfter: <sha> }, notes: "no new commits to push" }`.

### 2. Verify it's a fast-forward

```bash
git merge-base --is-ancestor "$remote_sha" "$local_sha" \
  || return error "local branch has diverged from origin/<branch> — refusing to push (would require force)"
```

This is the safety gate. If origin moved (someone pushed to the same branch concurrently, or the PR was rebased upstream), fail loudly. Never force-push.

### 3. Capture the new commits

```bash
new_commits=$(git rev-list "$remote_sha".."$local_sha")
```

### 4. Push

```bash
git push origin "<branch>"
```

If push fails (auth issue, branch protection, etc.) → return `{ approved: false, notes: "<exact stderr>" }`.

### 5. Return

```
{
  approved: true,
  artifacts: {
    pushed: true,
    newCommits: [<list>],
    headShaBefore: <remote_sha>,
    headShaAfter: <local_sha>
  }
}
```

## Rules

- **Never force-push.** No `--force`, no `--force-with-lease`. The fast-forward check above is the contract.
- **Never amend.** Commits made by `_revisit-pr`'s implementation step are already final by the time this skill runs.
- **Never push to `main` / `master`.** This skill is for feature branches only. If `<branch>` matches the configured base branch, abort.
- **Read-only on the worktree.** No file edits, no staging, no committing — those happened earlier. This skill only invokes `git push`.
