---
name: _announce-plan-completion
description: Attach the published GitHub issue to the primary Linear ticket as a linked resource — it shows up in the Linear ticket's Links panel, not as a comment in the Activity feed. Uses the Linear MCP's `save_issue` tool with the `links` parameter (append-only; same URL is never duplicated on re-run).
---

# Announce Plan Completion

Attaches the published GitHub issue URL to the primary Linear ticket as a linked resource. The link lands in the Linear ticket's "Links" panel — where cross-references belong — rather than as a comment in the activity feed. The assigner sees a clickable card with the GitHub issue's title and favicon, not a chat-style message.

## Inputs

```
{
  linearTicketUrl: "<url>",
  ticketCode:      "<ENG-11371>",
  issueUrl:        "<github issue url>"
}
```

## Procedure

1. Determine the ticket identifier. Prefer `ticketCode` if provided; otherwise extract from `linearTicketUrl` (e.g., `ENG-11371` from `https://linear.app/<org>/issue/ENG-11371/<slug>`).

2. Call `mcp__linear__save_issue` with the identifier and a `links` entry for the GitHub issue:

```
mcp__linear__save_issue({
  id:    "<TICKET-CODE>",
  links: [{
    url:   "<issueUrl>",
    title: "Hand of the King — <TICKET-CODE>"
  }]
})
```

The `links` parameter is append-only. If the GitHub issue is already attached to the ticket (e.g., a resumed session re-invoking this step), the MCP adds it as a duplicate entry — but Linear de-duplicates by URL and leaves the existing attachment intact. Either way, no comment is posted and no prior attachment is removed.

## Output

```
{ attached: boolean, notes?: string }
```

## Rules

- **No comment.** This skill never posts a Linear comment; the linked-resource is the signal. The GitHub issue itself carries the plan, the full context bundle, and the completion summary.
- **Title copy is fixed.** `Hand of the King — <TICKET-CODE>` — do not embellish or reword. Consistency is what lets anyone scanning the ticket's Links panel spot the thk handoff at a glance.
- If `save_issue` fails (Linear MCP unreachable, ticket not found, permissions), return `{ attached: false, notes: "<exact error>" }`. The Hand treats this as non-blocking — the published GitHub issue is still the authoritative handoff artifact.
- Do not touch any other field on the ticket (state, assignee, labels, description). This skill only appends to `links`.
