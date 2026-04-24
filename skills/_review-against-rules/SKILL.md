---
name: _review-against-rules
description: Review an uncommitted diff against codified rules — TypeScript (via static reading), linter conventions, and business rules documented in Notion. Produces a list of violations with citations. Static only — see `run-verification` for actually running tsc/build.
---

# Review Against Rules

## Inputs
```
{
  contextDir: "<abs>",
  workdir: "<abs>",
  cycle?: number
}
```

## Procedure

1. Read `<contextDir>/review-brief.md` — note the "Files Changed" list.
2. `cd <workdir> && git diff` — read the changes.
3. Consult Notion MCP for any documented rule on the touched modules (authorization, data handling, naming, package boundaries, API contracts). Query live.
4. Flag every law violation with a citation (Notion URL for business rules, file:line for code issues).

## Output
```
{
  approved: boolean,
  issues: [{ severity, rule: "tsc"|"lint"|"business", file, line?, description, suggestion?, citation? }],
  notes: string
}
```

## Rules
- Static only. Do not run the build — that's `run-verification`.
- Business-rule violations must cite the exact Notion page URL and relevant passage.
- If Notion MCP is unavailable, proceed with code-side checks and note the gap.
