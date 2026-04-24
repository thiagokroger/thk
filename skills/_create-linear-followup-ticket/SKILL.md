---
name: _create-linear-followup-ticket
description: Create a Linear ticket (typically a tech-debt follow-up), linked to a parent ticket via the `relatesTo` relationship. Uses the Linear MCP. Just creates — drafting the body is a separate skill (`draft-techdebt-ticket`).
---

# Create Linear Follow-up Ticket

## Inputs
```
{
  title: "<short title, under 80 chars>",
  body: "<markdown>",
  labels: string[],
  relatesTo: "<PARENT-CODE>"
}
```

## Procedure

Invoke `mcp__linear__save_issue` with the provided fields. Pass body with real newlines, not `\n`.

Link the new issue to the parent via the `relatesTo` relationship.

## Output
```
{ ticketCode: "<CODE>", ticketUrl: "<url>" }
```

## Rules
- Real newlines in MCP string content — no `\n` escapes.
- If the Linear MCP is unavailable, return `{ error: "Linear MCP unreachable" }`.
