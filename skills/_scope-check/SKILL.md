---
name: _scope-check
description: Mid-implementation scope check — compares the current diff size against an earlier effort estimate. Advisory; never blocks. Recommends continue / consider-minimal-fix / split-task, and names concrete carveouts when drifting.
---

# Scope Check

## Inputs
```
{
  workdir: "<abs>",
  originalEstimate: {
    tShirt, expectedFiles, expectedLoc, effortBand, budgetCeiling
  }
}
```

## Procedure

`cd <workdir> && git diff --stat` — read the current size. Compare against `originalEstimate`.

## Output
```
{
  currentFiles: number,
  currentLoc: number,
  drift: "within"|"over"|"significantly-over",   // >2x estimate = significantly-over
  recommendation: "continue"|"consider-minimal-fix"|"split-task",
  notes: string        // when drifting, name which parts could be carved out into a follow-up
}
```

## Rules
- Advisory, never a blocker.
- When drifting, be concrete: name the files or subsystem that could be deferred.
