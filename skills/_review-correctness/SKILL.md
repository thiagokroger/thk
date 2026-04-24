---
name: _review-correctness
description: Review an uncommitted diff for correctness and edge cases. Reads `root-cause-analysis.md` + `review-brief.md`, runs `git diff`, assesses whether the fix addresses the root cause, and looks for edge cases, regressions, and wiki-convention violations. Cites file:line for every finding.
---

# Review Correctness

## Inputs
```
{
  contextDir: "<abs>",
  workdir: "<abs>",
  cycle?: number
}
```

## Procedure

1. Re-read `<contextDir>/root-cause-analysis.md` and `<contextDir>/review-brief.md`.
2. `cd <workdir> && git diff` — read the actual diff.
3. Assess:
   - Does the fix address the **root** cause or only a symptom?
   - Edge cases — empty states, concurrency, pagination, timezone, locale, off-by-one, null/undefined, empty arrays, unicode.
   - Historical regressions — does `git log` on touched files reveal past fixes that this change might re-break?
   - Wiki alignment — any Notion-documented convention violated?
4. Do NOT flag items under "Intentional Design Decisions" in `review-brief.md`.

## Output
```
{
  approved: boolean,
  issues: [{ severity: "blocker"|"major"|"minor", file, line?, description, suggestion? }],
  notes: string
}
```

## Rules
- Cite evidence — file:line, commit sha, Notion URL.
- "I don't know" is a valid finding; state specific unknowns.
- Be concise — findings are either actionable or not.
