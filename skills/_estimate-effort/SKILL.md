---
name: _estimate-effort
description: Produce an upfront effort estimate for a ticket — t-shirt size, expected files / LoC delta, effort band, and a budget ceiling. Reads the captured Linear context and skims the workdir. Advisory only, never blocking.
---

# Estimate Effort

## Inputs
```
{
  ticketCode: "<ENG-123>",
  contextDir: "<abs>",
  workdir: "<abs>"
}
```

## Procedure

1. Read every file in `<contextDir>/linear/`. Note the shape: one-line bug? Feature with acceptance criteria? Unclear requirements?
2. Skim the workdir — ten minutes max. `Glob` for relevant files, `Grep` for mentioned symbols.
3. Produce a rough estimate.

## Output
```
{
  tShirt: "XS"|"S"|"M"|"L"|"XL",
  expectedFiles: number,
  expectedLoc: number,
  effortBand: "<30m"|"30m-2h"|"2h-1d"|"1d-3d"|">3d",
  budgetCeiling: "<e.g. 'exceeds 8 files or 300 LoC = flag scope creep'>",
  notes: string
}
```

## Rules
- Estimates are rough. "L, could be XL" beats a confident "M".
- Read-only — never modify the working tree.
- Caller decides how to act on the estimate; this skill doesn't block.
