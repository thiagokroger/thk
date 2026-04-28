---
name: _post-revisit-summary
description: Post the revisit-round summary to a PR — one issue-level comment summarizing the round, plus one threaded reply per finding (resolved / deferred / declined). Reads the triage table from `<contextDir>/pr-reviews/round-<N>/triage.md` and uses `gh api` to reply on the original review-comment threads. Used by `_revisit-pr` Step 6b after commits are pushed.
---

# Post Revisit Summary

Closes the loop with reviewers. After the Hand has pushed fixes, the PR threads are still showing CodeRabbit's original comments unresolved — this skill replies on each thread with the verdict so the conversation history is clean.

## Inputs

```
{
  prUrl:           "<https://github.com/owner/repo/pull/N>",
  round:           <int>,
  triagePath:      "<abs — <contextDir>/pr-reviews/round-<N>/triage.md>",
  deferredTickets?: [{ findingId: <n>, ticketUrl: "<url>" }, ...],   // from Master of Coin draft-techdebt-ticket
  accepts:         [{ findingId: <n>, threadId: "<id>", commitSha: "<sha>" }, ...],
  defers:          [{ findingId: <n>, threadId: "<id>" }, ...],
  declines:        [{ findingId: <n>, threadId: "<id>", reasoning: "<one-line>" }, ...]
}
```

`threadId` is GitHub's review-comment ID (`comments.id` from `gh pr view --json comments` or `gh api repos/.../pulls/N/comments`). Issue-level comments don't have threads, so findings sourced from those use `threadId: null` and only the summary comment references them.

## Output

```
{
  approved:    true,
  artifacts: {
    summaryCommentUrl: "<url>",
    repliesPosted:     <int>,
    repliesFailed:     [{ findingId: <n>, error: "<reason>" }, ...]
  },
  notes?: string
}
```

## Procedure

### 1. Sanity checks

- `gh auth status` — abort if not authenticated.
- Parse `<owner>/<repo>/<n>` from `prUrl`.
- `test -f <triagePath>` — abort if the triage file is missing (caller should have written it before invoking).

### 2. Compose the summary comment body

```markdown
## thk revisit — round <N>

| Verdict | Count |
|---|---|
| Resolved | <accepts.length> |
| Deferred | <defers.length> |
| Declined | <declines.length> |

Triage detail: [round-<N>/triage.md](<triage-link>)
New head: `<headShaAfter>`

<!-- thk-revisit-round: <N> -->
```

Substitute `<triage-link>` with the issue-bundle URL — the caller knows the bundle SHA from the next `update-github-issue` call. If the bundle hasn't been pushed yet at the time this skill runs, link to the local file path; the next `update-github-issue` will rewrite the body. (Practical note: post the comment with a placeholder, then `update-github-issue` is the one that fixes the body.)

### 3. Post the summary comment

```bash
gh pr comment <prUrl> --body "$summary_body"
```

Capture the resulting comment URL from the command output.

### 4. Reply on each thread

For each entry in `accepts`, `defers`, `declines` where `threadId` is set, post a threaded reply via the GitHub API:

```bash
gh api -X POST repos/<owner>/<repo>/pulls/<n>/comments/<thread_id>/replies \
  -f body="$reply_body"
```

Reply bodies:

- **Accepts:** `> Resolved by <commitSha> in this round.`
- **Defers:** `> Deferred to <ticketUrl> — out of scope for this PR. (Linked tech-debt ticket auto-drafted by Master of Coin.)`
- **Declines:** `> Declined: <reasoning>`

If `gh api` fails for a particular thread (thread closed, comment deleted, etc.), record the failure in `repliesFailed[]` but keep going — one bad thread doesn't block the rest.

### 5. Return

```
{
  approved: true,
  artifacts: {
    summaryCommentUrl: "<from step 3>",
    repliesPosted:     <count of successful replies>,
    repliesFailed:     [<list of failures>]
  }
}
```

## Rules

- **Tone is neutral and factual.** No effusive language, no apologies, no flourish. The reviewer asked for X, here's what happened to X.
- **Cite commits, not branches.** Reply bodies reference the exact commit SHA the fix landed in, not the branch name — the SHA is stable, the branch is mutable.
- **Don't resolve threads.** GitHub's "resolve conversation" button is the human reviewer's prerogative. We post the reply, they decide whether the thread is resolved.
- **Skip stale threads silently.** If a `threadId` no longer exists (the comment was deleted), record it in `repliesFailed` and continue — don't error the whole skill.
- **One summary comment per round.** Don't post a second summary if invoked twice for the same round; check the existing PR comments for `<!-- thk-revisit-round: <N> -->` and bail with a no-op if found.
