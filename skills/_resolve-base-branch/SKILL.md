---
name: _resolve-base-branch
description: Resolve the correct base branch for a new worktree. Defaults to `main` but detects Vercel preview URLs of the shape `<project>-pr-XXXX-preview.vercel.app` in the provided ticket text and, if found, returns that PR's head branch so the worktree inherits the preview's changes. Invoke before creating any worktree tied to a ticket.
---

# Resolve Base Branch

## Inputs
```
{
  ticketText: "<description + comments, concatenated>",
  workdir: "<absolute path to the repo — where `gh` runs>"
}
```

## Procedure

1. Search `ticketText` for a Vercel preview URL of the form `<project>-pr-(\d+)-preview\.vercel\.app`. Edit the regex to match your team's preview URL pattern (e.g., `my-app-pr-(\d+)-preview\.vercel\.app`).
2. If no match → return `{ baseBranch: "main" }`.
3. If a match → `cd <workdir> && gh pr view <PR_NUMBER> --json headRefName,baseRefName` and return the `headRefName` as the base.

## Output
```
{ baseBranch: "<name>", basedOnPr?: <PR number> }
```

## Rules
- If multiple preview URLs exist, use the first match.
- If `gh pr view` fails (closed PR, network error), fall back to `main` and note it in `notes`.
