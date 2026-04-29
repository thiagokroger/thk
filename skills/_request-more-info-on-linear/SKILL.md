---
name: _request-more-info-on-linear
description: Post a Linear comment @-mentioning the assigner when the Hand has decided the ticket is missing context it needs to proceed (status `needs-more-info`). This is the **only** path that pings humans on Linear — every other Linear interaction (publish-plan, draft-PR, revisit summary) is a passive Links-panel attachment or no Linear interaction at all. Use sparingly.
---

# Request More Info on Linear

The Hand reached `needs-more-info` — the captured context (ticket body, comments, Jam recordings, Figma designs) doesn't carry enough information to draft a plan or proceed safely. The right move is a targeted ping to the assigner explaining what's missing.

This is the **only** auto-ping path in thk. PR-ready notifications, plan-published links, and revisit summaries do not @-mention. The principle: pings interrupt humans; only interrupt them when their input is the bottleneck.

## Inputs

```
{
  linearTicketUrl: "<https://linear.app/.../issue/<CODE>>",
  ticketCode:      "<ENG-10105>",
  assigner:        "<name from capture-linear — e.g. \"Sergio\">",
  missingItems:    [
    "<one-line description of a specific gap, e.g. \"Reproduction steps for the mobile crash\">",
    "<another gap, e.g. \"Acceptance criteria — current behavior vs expected\">"
  ],
  notes?:          "<optional one-paragraph context — what the Hand did try>"
}
```

## Output

```
{
  approved:  true,
  artifacts: { commentUrl: "<linear-comment-url-or-id>" },
  notes?:    string
}
```

## Procedure

### 1. Sanity checks

- `linearTicketUrl` must be a valid Linear URL — abort if missing or malformed.
- `assigner` must be non-empty (otherwise the @-mention has nothing to anchor to). If absent → return `{ approved: false, notes: "no assigner; cannot @-mention. Skip the Linear ping and surface needs-more-info via outcome.md alone." }`.
- `missingItems` must be a non-empty array. Empty list → return `{ approved: false, notes: "missingItems is empty; nothing to ask for" }`. Don't post a vague "need more info" with no specifics — that's worse than no ping.

### 2. Compose the comment body

Use real newlines, not `\n` escape sequences (Linear MCP renders escape sequences literally).

```markdown
@<assigner> — thk needs more context to proceed on <TICKET-CODE>. Specifically:

- <missingItem-1>
- <missingItem-2>
- <missingItem-N>

<notes — only if provided, one paragraph>

Once added, re-run `/thk <linearTicketUrl>` and I'll pick up from there.
```

The closing line is important — it tells the assigner exactly how to unblock thk so they don't have to remember the incantation.

### 3. Post the comment

```
mcp__linear__save_comment({
  issueId: <derived from linearTicketUrl>,
  body: <composed body>,
  // mention is implicit via @<assigner> in the body — Linear parses it
})
```

If the MCP returns an error (auth issue, bad issue ID, etc.) → return `{ approved: false, notes: "<exact MCP error>" }`. Don't retry; the Hand surfaces the failure.

### 4. Return

```
{
  approved: true,
  artifacts: { commentUrl: <returned URL or comment ID from save_comment> },
  notes: "Posted @<assigner> mention with <N> missing-items list."
}
```

## Rules

- **Specific or silent.** Vague "the Hand needs more info" pings are spam. Each `missingItem` must be a concrete request the human can act on without re-reading the entire ticket.
- **One ping per `needs-more-info` outcome.** The Hand should not call this skill twice for the same ticket without new findings.
- **Use the assigner from `capture-linear`.** Don't infer — the Whisperer pulls the assigner cleanly. If absent in the captured ticket, abort rather than guess.
- **Keep the closing line.** The "re-run `/thk <url>`" line is the unblock contract; reviewers shouldn't have to remember syntax.
- **No PR URLs in this comment.** This skill runs at `needs-more-info`, before any plan or PR exists. If the caller is conflating outcomes, fail fast — don't just paste whatever they passed.
