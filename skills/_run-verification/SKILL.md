---
name: _run-verification
description: Run the verification gauntlet from a session's worktree — `pnpm i && tsc --noEmit && pnpm run build`. Pre-existing type errors on the branch are acceptable; new ones introduced by the diff are blockers. Never bypasses build failures.
---

# Run Verification

## Inputs
```
{
  workdir: "<abs>",
  appPath?: "<default: apps/web>"
}
```

## Procedure

From `<workdir>`:

```bash
pnpm i
cd <appPath> && npx tsc --noEmit
cd <workdir> && pnpm run build
```

- `pnpm i` is mandatory (branches differ in dependencies).
- `tsc --noEmit`:
  - Pre-existing errors on the branch: acceptable.
  - **New** errors introduced by the diff: blockers.
  - To disambiguate: `git stash && tsc --noEmit` shows the branch's baseline.
- `pnpm run build`: must pass. Never bypass. On failure, diagnose root cause (missing package → `pnpm add <pkg> --filter <app>`; broken import → fix path). Only accept a failure if conclusively proven pre-existing on the base branch.

## Output
```
{
  approved: boolean,
  issues: [{ severity: "blocker", stage: "install"|"tsc"|"build", description, suggestion? }],
  notes: string
}
```

## Rules
- Do not run the test suite — that's a separate gauntlet.
- Summarize long build logs; never dump them into the envelope.
- A build failure is always a blocker unless conclusively pre-existing.
