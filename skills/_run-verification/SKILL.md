---
name: _run-verification
description: Run the verification gauntlet from a session's worktree — install dependencies, type-check, build. Commands are inferred from the project's `package.json` and lockfile (no hardcoded `pnpm`/`tsc`/`build`). Overridable per-project via `<workdir>/.claude/.thk/policies.json`. Pre-existing baseline failures are acceptable; new failures introduced by the diff are blockers. Never bypasses build failures.
---

# Run Verification

A project-agnostic verification gauntlet. Detects the package manager from the lockfile, looks up the type-check and build commands from `package.json` scripts (with sensible fallbacks), and runs them in order. Per-project overrides live in `<workdir>/.claude/.thk/policies.json`.

## Inputs
```
{
  workdir: "<abs — repo / worktree root>",
  appPath?: "<abs — sub-package path for monorepos when typecheck/build need to run from a leaf rather than root; defaults to <workdir>>"
}
```

## Procedure

### 1. Resolve the three commands

Three commands to run: **install**, **typecheck**, **build**. Each resolves via the same precedence:

1. **Override** in `<workdir>/.claude/.thk/policies.json` wins. Format:

   ```json
   {
     "verification": {
       "install":   "pnpm install --frozen-lockfile",
       "typecheck": "pnpm tsc --noEmit",
       "build":     "pnpm run build",
       "test":      null
     }
   }
   ```

   `null` means "skip this step explicitly". A missing key falls through to inference.

2. **Inference from `<workdir>/package.json` + lockfile** if no override.

3. **Skip** if inference also can't resolve a command (e.g., no `build` script and no obvious build runner).

#### Inferring the package manager (used for install + script invocations)

Read whichever lockfile is present in `<workdir>` (first match wins):

| Lockfile | Package manager | Install command |
|---|---|---|
| `pnpm-lock.yaml` | `pnpm` | `pnpm install --frozen-lockfile` |
| `yarn.lock` | `yarn` | `yarn install --frozen-lockfile` |
| `package-lock.json` | `npm` | `npm ci` |
| `bun.lockb` | `bun` | `bun install --frozen-lockfile` |
| (none, only `package.json`) | `npm` | `npm install` |

If `<workdir>/package.json` doesn't exist at all → return `{ error: "no package.json found at <workdir>; declare custom verification commands in .claude/.thk/policies.json (verification.install / verification.typecheck / verification.build) or AGENTS.md" }`. The verification gauntlet's default inference is JS-package-shaped; a Python / Go / Rust / PHP project must declare its own commands via overrides.

The lockfile is the **declared** truth — don't fall back to `which pnpm` on the machine. If a teammate's machine doesn't have `pnpm` installed when the lockfile says pnpm, the install will fail loudly, which is correct.

#### Inferring the typecheck command

Read `<workdir>/package.json` (or `<appPath>/package.json` if `appPath` is set):

1. **Script lookup** — first match in `scripts.typecheck`, `scripts.tsc`, `scripts.check-types`, `scripts.type-check`. If found: `<pkg-mgr> run <script-name>`.
2. **TypeScript dep present** — if `typescript` is in `dependencies` or `devDependencies`: `<pkg-mgr> exec tsc --noEmit` (for `pnpm` / `yarn` / `bun`) or `npx tsc --noEmit` (for `npm`).
3. **No TypeScript** — skip the typecheck step. Note in `notes`: "no TypeScript detected — skipped typecheck".

#### Inferring the build command

Read `<workdir>/package.json` (or `<appPath>/package.json`):

1. **`scripts.build` present** → `<pkg-mgr> run build`.
2. **Absent** → skip the build step. Note: "no `build` script — skipped build".

This skip is **not** a failure. Many libraries ship source-only (no compile step), and skipping is correct for those. The blocker is when `build` is *expected to exist and fails* — see Rules below.

### 1.5. Persist what was inferred (first-run only)

If any of `verification.{install,typecheck,build}` was **inferred** (not read from an existing `policies.json` override), write the inferred values back to `<workdir>/.claude/.thk/policies.json` so subsequent runs skip inference and the team can review / commit / edit the file. This is the auto-bootstrap behavior.

Behavior:

- If `<workdir>/.claude/.thk/policies.json` doesn't exist → create it with a `_meta` block + the inferred `verification` block.
- If it exists but lacks `verification.<key>` → merge in only the missing keys, leave existing values alone.
- If every key was already present → skip the write entirely (no churn).
- After writing, if the `_meta` block changed, log a one-line stderr notice: `_run-verification: wrote inferred verification commands to <workdir>/.claude/.thk/policies.json — review and edit if wrong.`

File shape:

```json
{
  "_meta": {
    "generatedBy": "_run-verification",
    "generatedAt": "<ISO 8601>",
    "inferenceSource": "lockfile=<which> + package.json scripts",
    "note": "Edit freely. thk reads this verbatim on subsequent runs. Hand-edited values are NOT overwritten — _run-verification only fills missing keys."
  },
  "verification": {
    "install":   "<inferred command>",
    "typecheck": "<inferred command, or null if skipped>",
    "build":     "<inferred command, or null if skipped>"
  }
}
```

Use `null` (not omission) for skipped steps so subsequent runs can distinguish "intentionally off" from "not yet decided".

`policies.json` is **committed** by default — `_scaffold-session` (and `install.sh`) writes a `.gitignore` block of the form `.claude/.thk/` + `!.claude/.thk/policies.json` so this file rides along with the team while everything else under `.claude/.thk/` stays per-developer.

### 2. Execute

Run the resolved commands in order, from `<workdir>`:

```bash
cd <workdir>
<install_command>
```

For typecheck and build, run from `<appPath>` if set, otherwise `<workdir>`:

```bash
cd <appPath ?? workdir>
<typecheck_command>     # if not skipped
<build_command>         # if not skipped
```

Capture exit codes. A non-zero exit code on any command is a blocker.

### 3. Diagnose pre-existing baseline failures

Type-checks and builds can fail because of code already on the branch (not introduced by the diff). To distinguish:

```bash
cd <workdir>
git stash
<typecheck_command>
git stash pop
```

If the baseline already fails the same way → the failure is **pre-existing**. Note it in `notes` and don't block. New failures introduced by the diff → **blocker**.

For build failures specifically: never bypass. Diagnose root cause (missing package, wrong import path, etc.). Only accept a failure if conclusively proven pre-existing on the base branch.

### 4. Output

```
{
  approved: boolean,                              // true iff every non-skipped step succeeded
  packageManager: "pnpm" | "yarn" | "npm" | "bun",
  resolvedCommands: {
    install: "<exact command run>",
    typecheck: "<exact command run, or null if skipped>",
    build: "<exact command run, or null if skipped>"
  },
  skippedSteps: ["typecheck"|"build", ...],       // empty if all ran
  issues: [{ severity: "blocker", stage: "install"|"typecheck"|"build", description, suggestion? }],
  notes: string
}
```

## Rules

- **Inference is from the lockfile, not from `$PATH`.** The lockfile is the project's declared package manager. Don't override based on what the host has installed.
- **No silent fallback when a step is configured but fails.** Skipping is allowed only when the step doesn't exist (no script, no TypeScript). If `package.json` declares `scripts.build` and it fails, that's a blocker.
- **Pre-existing baseline failures are acceptable** — must be conclusively proven via `git stash` comparison. Don't accept a build failure as "probably pre-existing" without checking.
- **Don't run the test suite by default.** Tests are typically slower and noisier than the gauntlet; opt in via `verification.test` override if a project wants them in the gauntlet.
- **Summarize long output.** Build logs can be megabytes. Capture the last ~20 lines of any failing command into the envelope's `notes`; write the full output to `<workdir>/.claude/.thk/sessions/<id>/log.md` if useful for debugging.
- **A build failure is always a blocker unless conclusively pre-existing.**
