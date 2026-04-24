---
name: _scaffold-session
description: Create the session folder layout at an absolute path — `<sessionPath>/{worktree,assets-worktree,context}` plus a skeleton `progress.md`. Creates two git worktrees of the target repo: the code worktree on the session branch (forked from base) and the assets worktree on an orphan history backed by `refs/thk/<ticket>`. Runs `pnpm i` inside the code worktree. Idempotent — resuming an existing session returns the same paths without overwriting.
---

# Scaffold Session

## Inputs
```
{
  sessionId:   "<YYYY-MM-DD_HHMMSS_slug>",
  sessionPath: "<abs — e.g. <targetRepo>/.thk/sessions/<sessionId>>",
  targetRepo:  "<abs — the product repo to worktree from>",
  baseBranch:  "<base branch in targetRepo>",
  branchName:  "<new branch to create>",
  ticketCode:  "<ENG-123>",
  ticketUrl:   "<linear URL>"
}
```

All four paths are absolute. The session lives under `<targetRepo>/.thk/sessions/<sessionId>` — **inside** the target repo. The `.thk/` directory must be excluded by git so session folders don't show up in `git status`. Two paths get there: `install.sh` adds it to `.gitignore` with explicit consent during setup, OR — for users who installed via the Claude Code marketplace and never ran the script — this skill auto-adds it on first run. Either way, by the time the first session folder is created, `.thk/` is excluded.

## Procedure

```bash
# Ensure .thk/ is gitignored — the marketplace install path skips install.sh
# entirely, so this skill is the second line of defense. Logic:
#   1. If .thk/ already in <targetRepo>/.gitignore → no-op.
#   2. Else if .thk/ already in <targetRepo>/.git/info/exclude → no-op.
#      (User opted into the repo-local list explicitly; respect that signal
#      and don't duplicate the entry into the committed .gitignore.)
#   3. Else → append .thk/ to <targetRepo>/.gitignore and log a one-line
#      notice to stderr. The committed entry is shared across the team, so
#      anyone else cloning gets the exclude automatically.
if grep -qxF '.thk/' <targetRepo>/.gitignore 2>/dev/null; then
  : # already excluded via .gitignore
elif grep -qxF '.thk/' <targetRepo>/.git/info/exclude 2>/dev/null; then
  : # excluded via the repo-local list — user signaled that path
else
  # If .gitignore exists and lacks a trailing newline, add one before the entry
  if [ -f <targetRepo>/.gitignore ] && [ -s <targetRepo>/.gitignore ] \
     && [ -n "$(tail -c 1 <targetRepo>/.gitignore 2>/dev/null)" ]; then
    printf "\n" >> <targetRepo>/.gitignore
  fi
  printf ".thk/\n" >> <targetRepo>/.gitignore
  echo "scaffold-session: added '.thk/' to <targetRepo>/.gitignore (was missing — sessions would have appeared in 'git status')." >&2
fi

mkdir -p \
  <sessionPath>/context/plan-reviews/round-1-plan \
  <sessionPath>/context/plan-reviews/round-2-plan \
  <sessionPath>/context/plan-reviews/round-1-diff \
  <sessionPath>/context/plan-reviews/round-2-diff

cd <targetRepo>
git fetch origin <baseBranch>
git worktree add -b <branchName> <sessionPath>/worktree origin/<baseBranch>

cd <sessionPath>/worktree
pnpm i
```

Note: `git worktree add` accepts an absolute path, so the worktree lives under `<sessionPath>/` (inside `<targetRepo>/.thk/sessions/<sessionId>/worktree/`) while still being a valid checkout of `<targetRepo>`. Commits made there push to `<targetRepo>`'s origin. The `.gitignore` entry on `.thk/` keeps it from showing as untracked in the main checkout's `git status`.

### Assets worktree on a custom ref

The session also needs a **second worktree** where asset-bundle commits live. Those commits never touch `refs/heads/*` (branches) or `refs/tags/*` (tags) — they go to `refs/thk/<TICKET-CODE>`, a custom namespace that is invisible in the branch picker and tags tab, but is a real ref that pins its commits forever.

```bash
assetsRef="refs/thk/<TICKET-CODE>"
assetsLocalBranch="_thk_assets_<TICKET-CODE>"   # local-only throwaway branch name for the worktree
assetsWorktree="<sessionPath>/assets-worktree"

cd <targetRepo>

# Try to hydrate an existing ref from origin (resumption or re-open of a ticket).
# `git fetch` with a custom refspec writes to a local ref with the same name.
git fetch origin "$assetsRef:$assetsRef" 2>/dev/null || true

if git rev-parse --verify --quiet "$assetsRef" >/dev/null; then
  # Existing ref — worktree from its current tip so the new commit chains naturally.
  git worktree add -b "$assetsLocalBranch" "$assetsWorktree" "$assetsRef"
else
  # First session for this ticket — create an orphan history.
  # `git worktree add --orphan` (git >= 2.42) creates a detached orphan worktree
  # with an empty index and no commits yet.
  git worktree add --orphan -b "$assetsLocalBranch" "$assetsWorktree"
fi
```

- **No `pnpm i` here** — the assets worktree has no code and no `package.json`. It's a scratch space for the bundle commit.
- **The local branch name** (`_thk_assets_<TICKET-CODE>`) is a convenience label for the worktree checkout; it never gets pushed. All pushes go to `refs/thk/<TICKET-CODE>`.
- **The resumption path hydrates from origin first** so a freshly-cloned repo resuming someone else's session picks up the existing ref history.

**Resumption:** if `<sessionPath>/worktree/` already exists, skip `git worktree add` and `pnpm i` for the code worktree. Mirror the same skip for `<sessionPath>/assets-worktree/`. Ensure the four `plan-reviews/round-{1,2}-{plan,diff}/` directories exist (idempotent `mkdir -p`). Sessions created by older versions of this skill may still have the un-suffixed `round-1/` / `round-2/` / `round-3/` layout — leave them in place; the meeting skill reads whichever it finds.

### Write the context README

Write `<sessionPath>/context/README.md` **only if it does not already exist** — this is the entry-point map for downstream agents (Codex, Gemini, a human developer) who open the context folder cold:

```markdown
# Context folder — index

This folder is the shared intelligence for a single thk session. A downstream agent or developer reading this folder should start here. Everything needed to pick up the work lives inside this directory.

## Top-level files

- `plan.md` — the living plan, revised after each review round. Source of truth for what to implement.
- `README.md` — this file.
- `outcome.md` — present only when the run stopped on a blocking outcome (`already-fixed`, `needs-more-info`, `plan-published-review-failed`, `failed`).
- `root-cause-analysis.md` — Grand Maester's analysis of the bug's origin, when present.
- `review-brief.md` — Hand's fix approach notes, when present.

## Captured evidence (subfolders)

- `linear/` — one markdown file per ticket from the Linear MCP (primary + any linked, parent, sub, related). Each file has the ticket description, metadata, and full comment thread. Future ticket sources land in peer folders, e.g. `jira/`.
- `jam/<jam-id>/` — one folder per Jam recording:
  - `details.md` — recording metadata (author, duration, browser, system info).
  - `transcript.md` — video transcript (video jams only).
  - `analysis.md` — AI analysis of user intents and visual findings (video jams only).
  - `console.md` — every browser console entry, chronological.
  - `network.md` — every network request, chronological.
  - `user-events.md` — user interaction timeline.
  - `screenshots/` — PNG screenshots (keyframes on video jams, captured frames on screenshot jams).
- `figma/<node-id>/` — one folder per Figma design:
  - `context.md` — code snippets, annotations, Code Connect mappings.
  - `metadata.json` — file structure metadata.
  - `variables.json` — design tokens.
  - `screenshots/` — PNG screenshots.
  - `html/` — HTML exports (if provided).
- `planetscale/<queryName>.md` — read-only SELECT query results, produced by the Grand Maester on his own judgment during Step 3a when a ticket or plan hinges on a specific record's state. Absent for tickets with no data-dependent question.

## Council deliberation — `plan-reviews/`

The council reviews `plan.md` in three rounds. Rounds 1 and 2 are reviewer output; Round 3 is the Hand's synthesis.

A meeting (when the Hand convenes one at Step 3) writes into four sub-folders, one per phase × round:

- `plan-reviews/round-1-plan/` — plan-phase member reviews (Step 1 of `_convene-meeting` plan phase): `grand-maester.md`, `master-of-laws.md`, `lord-commander.md`, `master-of-coin.md`.
- `plan-reviews/round-2-plan/` — plan-phase Counselor oversight.
- `plan-reviews/round-1-diff/` — diff-phase member reviews of the executed change (Step 1 of `_convene-meeting` diff phase, run after Step 5 execute).
- `plan-reviews/round-2-diff/` — diff-phase Counselor oversight.

Plus, in the no-meeting flow, the Counselor's pre-PR diff review lands as a single file:

- `plan-reviews/counselor-pre-pr.md` — the Step 6a Counselor sanity check (no-meeting flow only).

And across both flows:

- `plan-reviews/hand-decision.md` — single audit trail. Sections 1–2 = Hand's verdicts on plan-phase Round 1 + Round 2 (meeting flow only). Sections 3–4 = Hand's verdicts on diff-phase Round 1 + Round 2 (meeting flow), or the Hand's notes on the Counselor's pre-PR review (no-meeting flow).
```

Write skeleton `progress.md` at `<sessionPath>/progress.md` **only if the file does not already exist**:

```markdown
# Session Progress — <ticketCode>

**Session ID:** <sessionId>
**Ticket:** <ticketCode>
**Ticket URL:** <ticketUrl>
**Started:** <ISO 8601 now>
**Last updated:** <ISO 8601 now>
**Status:** in-progress
**Runtime profile:** <filled by Hand after profile resolution>

## Steps

### 1 — Capture
- State: pending

### 2a — Plan draft
- State: pending

### 2b — Publish plan to GitHub
- State: pending

### 3a — Council reviews (Round 1, profiled)
- State: pending

### 3b — Hand's decisions + issue update
- State: pending

### 3c — Counselor oversight (Round 2)
- State: pending

### 3d — Counselor decisions + final issue update
- State: pending

### 3e — Announce completion on Linear
- State: pending

## Notes
```

## Output
```
{
  sessionPath:        "<abs>",
  worktreePath:       "<abs — <sessionPath>/worktree>",
  assetsWorktreePath: "<abs — <sessionPath>/assets-worktree>",
  assetsRef:          "refs/thk/<TICKET-CODE>",
  contextPath:        "<abs — <sessionPath>/context>",
  progressPath:       "<abs — <sessionPath>/progress.md>",
  branchName:         "<name>",
  wasResumed:         boolean
}
```

## Rules
- Idempotent. Never overwrite existing `progress.md` or clobber an existing worktree (either one).
- No `git add .`; no destructive options.
- All paths passed in must be absolute. Do not resolve relative paths — the Hand is responsible for resolving `targetRepo` and `sessionPath` at step 0.
- The assets worktree is a **second** worktree of the same `<targetRepo>` repo on an orphan history. It must live at `<sessionPath>/assets-worktree/` so `cleanup-session` can tear it down by path, and so `git worktree list` stays tidy.
- Requires **git >= 2.42** for `git worktree add --orphan`. If the installed git is older, the Hand should fail early with a clear message rather than working around it — the rest of the flow depends on the orphan worktree.
- If the caller explicitly asked to skip worktrees (rare — not the default), `cd <targetRepo> && git checkout -b <branchName> origin/<baseBranch> && pnpm i` and set `worktreePath` to `<targetRepo>`. Most callers should NOT do this — it would touch the target repo's working tree, which thk's design avoids.
