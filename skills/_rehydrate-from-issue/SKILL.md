---
name: _rehydrate-from-issue
description: Reconstruct a thk session folder from a published GitHub issue and the orphan asset commit it points to. Reads `<!-- thk-assets-ref -->` and `<!-- thk-runner-profile -->` markers from the issue body, fetches the asset ref, copies session-log.md / session-progress.md / session-runtime-profile.json / context/ into a new session folder under `<targetRepo>/.thk/sessions/<id>/`, and adds a worktree at the PR head branch. Used by `_revisit-pr` (cold-start path) and any other future re-entry that needs to pick up where a prior run left off without local state.
---

# Rehydrate from Issue

The Hand publishes a self-contained handoff bundle to a GitHub issue (see `_publish-plan-to-github`). This skill is the reverse — given the issue URL, reconstruct enough local state that the Hand can resume.

Used by `_revisit-pr` when invoked on a fresh checkout, a different machine, or after `_cleanup-session` removed the prior session folder. May be reused by future entry points that need cold-start support.

## Inputs

```
{
  ticketCode:  "<ENG-10105>",
  issueUrl:    "https://github.com/<owner>/<repo>/issues/<n>",
  targetRepo:  "<abs — repo root>"
}
```

## Output

```
{
  approved:       true,
  artifacts: {
    sessionRoot:        "<abs — <targetRepo>/.thk/sessions/<reused-id>/>",
    contextDir:         "<abs — <sessionRoot>/context/>",
    workdir:            "<abs — <sessionRoot>/worktree/ at PR head>",
    assetsRef:          "refs/thk/<TICKET-CODE>",
    assetsSha:          "<40-char SHA of the bundle commit we read from>",
    priorRuntimeProfile: { ... },           // parsed from runtime-profile.json
    headBranch:         "<branch the PR head points at>",
    headSha:            "<40-char SHA of the worktree HEAD>",
    prUrl?:             "<from runtime-profile.json if recorded>"
  },
  notes?: string
}
```

## Procedure

### 1. Sanity checks

- `gh auth status` — abort if not authenticated.
- `cd <targetRepo> && git remote get-url origin` — confirm a GitHub remote.
- Parse `<owner>/<repo>` from the remote.
- Parse the issue number from `issueUrl`.

### 2. Read the issue body and parse markers

```bash
body="$(gh issue view <issueUrl> --json body --jq .body)"
```

Extract two markers:

```bash
assets_ref=$(printf '%s\n' "$body" | grep -oE '<!-- thk-assets-ref: [^ ]+ -->' | head -1 | sed 's|<!-- thk-assets-ref: \(.*\) -->|\1|')
runner_profile=$(printf '%s\n' "$body" | grep -oE '<!-- thk-runner-profile: [^ ]+ -->' | head -1 | sed 's|<!-- thk-runner-profile: \(.*\) -->|\1|')
```

If either is empty → return `{ approved: false, notes: "issue body missing thk markers — not a thk-managed issue" }`.

### 3. Fetch the asset ref into the local repo

```bash
cd <targetRepo>
git fetch origin "${assets_ref}:${assets_ref}"
assets_sha=$(git rev-parse "${assets_ref}")
```

If the fetch fails (ref deleted, repo moved) → abort with the exact error.

### 4. Find the bundled session-id inside the asset commit

The bundle path is `.github/thk-assets/<session-id>/`. List the commit's tree to find the session id:

```bash
session_id=$(git ls-tree --name-only "${assets_sha}" .github/thk-assets/ | head -1 | xargs basename)
```

If missing → return `{ approved: false, notes: "asset commit has no .github/thk-assets/<id>/ entry" }`.

### 5. Mint the new local session folder

By convention, a revisit reuses the same session-id but appends a sub-segment so it's distinguishable on disk:

```bash
new_session_id="${session_id}-revisit-$(date -u +%Y%m%d_%H%M%S)"
session_root="<targetRepo>/.thk/sessions/${new_session_id}"
mkdir -p "${session_root}/context"
```

### 6. Extract the bundle into the session folder

Use `git archive` to pull just the relevant subtree out of the asset commit without checking it out:

```bash
cd <targetRepo>
git archive "${assets_sha}" ".github/thk-assets/${session_id}/" \
  | tar -x -C "${session_root}" --strip-components=3
```

After extraction the layout is:

```
${session_root}/
├── session-log.md             ← from bundle
├── session-progress.md        ← from bundle
├── session-runtime-profile.json
└── context/
    ├── plan.md
    ├── linear/...
    ├── jam/...
    ├── figma/...
    └── plan-reviews/...
```

Rename the session-meta files into the canonical session-root names:

```bash
mv "${session_root}/session-log.md"               "${session_root}/log.md"
mv "${session_root}/session-progress.md"          "${session_root}/progress.md"
mv "${session_root}/session-runtime-profile.json" "${session_root}/runtime-profile.json"
```

The skill exposes them via the `session-` prefix when bundling and strips it back on rehydrate so the in-memory layout matches a warm session exactly.

### 7. Read prior runtime profile + PR URL

```bash
prior_profile=$(cat "${session_root}/runtime-profile.json")
pr_url=$(printf '%s' "$prior_profile" | jq -r '.prUrl // empty')
```

`prUrl` may be absent for sessions that didn't reach Step 7 (PR open). The caller (`_revisit-pr`) handles that — it can derive the PR URL from the Linear ticket links instead.

### 8. Determine the head branch + add a worktree

The head branch was recorded in `runtime-profile.json` (key `branchName` from `_scaffold-session`):

```bash
head_branch=$(printf '%s' "$prior_profile" | jq -r '.branchName // empty')
```

If empty → return `{ approved: false, notes: "runtime-profile.json missing branchName; cannot derive worktree head" }`.

```bash
git fetch origin "${head_branch}"
git worktree add "${session_root}/worktree" "origin/${head_branch}"
head_sha=$(git -C "${session_root}/worktree" rev-parse HEAD)
```

If `git worktree add` fails because a worktree at that path already exists (rerun on the same machine), reuse it: `cd "${session_root}/worktree" && git fetch origin "${head_branch}" && git reset --hard "origin/${head_branch}"`.

### 9. Note in progress.md that this is a rehydrated session

Append to `${session_root}/progress.md`:

```markdown
---

## Rehydrated session

- Source bundle: `${assets_ref}` @ `${assets_sha}`
- Original session-id: `${session_id}`
- Rehydrated at: <ISO 8601>
- Rehydrated by: `_rehydrate-from-issue`
```

### 10. Return

```
{
  approved: true,
  artifacts: {
    sessionRoot:        "${session_root}",
    contextDir:         "${session_root}/context",
    workdir:            "${session_root}/worktree",
    assetsRef:          "${assets_ref}",
    assetsSha:          "${assets_sha}",
    priorRuntimeProfile: <parsed JSON>,
    headBranch:         "${head_branch}",
    headSha:            "${head_sha}",
    prUrl:              "${pr_url}"
  }
}
```

## Rules

- **Read-only on the asset side.** Never modify the orphan ref. The asset commit is immutable history; this skill only consumes it.
- **Idempotent.** Running twice on the same issue produces two distinct rehydrated session folders (different timestamps in the new id). The caller decides which to keep.
- **No automatic merge.** This skill does not pull, merge, or rebase the head branch. It checks out exactly what `origin/${head_branch}` points at right now. Drift between local and remote is the caller's problem.
- **No `_scaffold-session` re-run.** Scaffold creates the orphan ref and the empty assets-worktree; on rehydrate those already exist remotely (we just fetched them). Don't reinitialize them.
- **Do not log inside this skill.** Logging is the agent's responsibility — the Master of Ships logs `skill-invoke` / `dispatch-detail` / `skill-return` around the call. This skill stays silent so it can be reused outside `_revisit-pr` without coupling to the log path.
