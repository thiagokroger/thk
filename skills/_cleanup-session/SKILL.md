---
name: _cleanup-session
description: Tear down a thk session — removes both git worktrees cleanly (`git worktree remove` for the code worktree and the assets worktree), and optionally deletes the entire session folder at the given absolute path. Preserves the folder when explicitly asked, for audit. Never touches the custom ref `refs/thk/<ticket>` — that stays forever by design.
---

# Cleanup Session

## Inputs
```
{
  sessionPath:        "<abs — the session folder to tear down>",
  worktreePath:       "<abs — <sessionPath>/worktree>",
  assetsWorktreePath: "<abs — <sessionPath>/assets-worktree>",
  preserveContext?:   boolean     // default false
}
```

## Procedure

```bash
git worktree remove <worktreePath>
git worktree remove <assetsWorktreePath>
```

Use `--force` only if the caller explicitly asks. If either remove fails because the path doesn't exist (session already half-cleaned), swallow silently — cleanup is idempotent.

If `preserveContext` is false or omitted:

```bash
rm -rf <sessionPath>
```

If `preserveContext` is true: leave the session folder in place (context files, reviews, and `log.md` stay). Both worktrees are still removed so git doesn't hold stale metadata.

## Output
```
{ removed: boolean, preserved: boolean }
```

## Rules
- **Path guard.** Before `rm -rf <sessionPath>`, verify the path contains `/.claude/.thk/sessions/` as a segment. A caller passing a path outside that tree is a bug — refuse and return `{ error: "sessionPath not inside <targetRepo>/.claude/.thk/sessions/" }`. This is the last line of defense against wiping unrelated directories.
- **Never delete the custom ref.** `refs/thk/<TICKET-CODE>` on origin stays forever — that's the whole point of the design. Months later, someone tracking down a regression can `git fetch origin 'refs/thk/*:refs/thk/*'` and browse the bundled context. This skill removes local worktrees only; it does not run `git push --delete` on the ref, and it does not run `git update-ref -d` locally on that ref either.
- If `git worktree remove` fails, investigate before using `--force` — a worktree may have uncommitted changes the caller didn't expect.
- `preserveContext: true` is the right call if the session ended on an interesting outcome (already-fixed, needs-more-info, or a review the King wants to read later). Default-false cleanup is for normal happy-path exits where the GitHub issue already carries everything.
