---
name: _draft-techdebt-ticket
description: Draft the body of a tech-debt follow-up Linear ticket. Produces the content (title, body, labels, parent link) — does NOT create the ticket. Pair with `create-linear-followup-ticket` for actual creation.
---

# Draft Tech-Debt Ticket

## Inputs
```
{
  parentTicketCode: "<ENG-123>",
  carveoutDescription: "<what was deferred>",
  workdir: "<abs>"
}
```

## Procedure

Produce a clean, picker-up-able ticket body:

- **Context** — why this was deferred (cite the parent).
- **What's needed** — concrete enough that someone else can pick it up.
- **Acceptance criteria** — how to know it's done.
- **Link** — `Relates to: <parent>`.

## Output
```
{
  title: "<concise, under 80 chars>",
  body: "<markdown>",
  labels: ["tech-debt"],
  relatesTo: "<parent code>"
}
```

## Rules
- Output is a draft payload, not a created ticket.
- Keep the body concrete — the future picker-upper won't have the original context.
