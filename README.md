# thk — The Hand of the King

A profile-driven orchestrator that currently ships as a Claude Code plugin and takes a ticket from "just filed" all the way to a Draft PR — capturing context, planning, reviewing, executing, and opening the PR in a single resumable call.

The Hand is the protagonist. The King brings a ticket; the Hand runs the flow to completion in one call — capturing every piece of context (ticket threads, Jam recordings, Figma designs, targeted PlanetScale lookups), drafting an implementation plan, deciding whether to summon the **Small Council** (Grand Maester, Master of Laws, Lord Commander, Master of Coin, Counselor) for a four-lens review plus oversight pass, executing the plan as a single agent, and opening a Draft PR with a description composed by the Grand Maester. The published GitHub issue carries the full plan + bundled context (Council reviews when summoned) so any downstream agent or human reviewer lands on the complete chronicle with one click.

One call: `/thk <ticket-url>`.

**Where the pluggability actually lives.** thk **is a Claude Code plugin** — the Hand depends on Claude Code's runtime (`Agent` dispatch, `Skill` invocation, MCP host, slash commands). It does not run standalone on Codex / Gemini / Cursor. Two things *are* pluggable inside that:

- **Ticket source MCP** — Linear today (via `capture-linear`); Jira or another tracker plugs in as a sibling `capture-<source>` skill. The rest of the flow doesn't know which tracker the ticket came from.
- **Council member + Counselor runners** — review/advisor roles can be wired to Claude, Codex CLI, or Gemini CLI through the profile system (`config/profiles.json`). The default profile uses Codex for the Counselor.

The Hand itself is not agnostic and isn't trying to be.

The Hand is a **state-aware entry point**. On every invocation it reads the session's `progress.md`, figures out where the ticket currently is — fresh / mid-capture / plan-published / Council-decided / executed — and picks up from the first incomplete step. Trivial tickets ship straight from the published plan (Council skipped); complex ones get the four-lens review. Both paths converge on `execute-plan` and an open Draft PR.

See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the design. See [`skills/thk/SKILL.md`](./skills/thk/SKILL.md) for the canonical runtime spec.

## Requirements

- Claude Code (desktop, CLI, or IDE) with `/plugin` support for the current plugin frontend
- `gh` CLI, authenticated with access to this repo (`gh auth status` must be green)
- MCP servers configured in Claude Code: `linear`, `Jam`, `figma`, `planetscale`, `notion`
- Access to whichever target git repo you intend to operate on
- Optional model CLIs for non-default profiles, such as `codex` or `gemini`

## Install

Two paths — pick one.

### Option A — guided installer (recommended)

Run from the root of the repo you want thk to operate on:

```bash
curl -fsSL https://raw.githubusercontent.com/thiagokroger/thk/main/install.sh | bash
```

The script:

1. Verifies Claude Code is on this machine. (Required — thk is a Claude Code plugin.)
2. Detects optional advisor runners (Codex CLI, Gemini CLI). Each one detected becomes an option in the profile picker; missing ones are hidden.
3. Walks you through three picks via a `gum`-powered checkbox UI (with a plain-`bash` fallback if `gum` isn't installed):
   - **Profile** — which model runs each council role (`claude_codex` is the default).
   - **Ticket source MCP** — Linear today; Jira and others slot in later via sibling `capture-<source>` skills.
   - **Optional capture MCPs** — Jam, Figma, PlanetScale, Notion.
4. Writes `<repo>/.claude/.thk/config.json` with the choices.
5. Checks `<repo>/.gitignore` for `.claude/.thk/`; if missing, prompts to add it (recommended, with a skip option). The committed entry keeps sessions, secret keys, and runtime state out of git for everyone on the team. If you skipped Jam in step 3, the gitignore step is purely about session folders.
6. If you enabled Jam capture, optionally prompts for a Jam personal access token (used by `capture-jam` to download videos and ffmpeg-extract frames at transcript timestamps). Stored at `<repo>/.claude/.thk/keys/jam.key` with `chmod 600` inside a `chmod 700` `keys/` dir. Skip-friendly — frame extraction degrades gracefully without it. Future per-source secrets (Linear, GitHub, …) follow the same `<repo>/.claude/.thk/keys/<source>.key` convention.
7. Prints the two `/plugin marketplace add` + `/plugin install` lines you need to paste into a Claude Code session, plus a reminder of which MCP servers your Claude Code MCP config needs to expose.

Re-run the script any time to change the profile / source / captures — it prompts before overwriting an existing config.

Flags: `--target-repo PATH` (operate on a different repo), `--profile NAME` (skip the profile picker), `--non-interactive` (use the defaults — `claude_codex`, Linear, all four optional captures).

### Option B — manual install

Skip the script and paste these straight into a Claude Code session:

```
/plugin marketplace add thiagokroger/thk
/plugin install thk@thiago-tools
```

`/plugin marketplace add` clones the repo via `gh`'s git credentials, reads `.claude-plugin/marketplace.json`, and registers the `thiago-tools` marketplace. `/plugin install thk@thiago-tools` then installs the `thk` plugin from that marketplace into your local Claude Code plugins cache (the `@` reads as "from"; `<plugin-name>@<marketplace-name>`). If the first command fails with an auth error, run `gh auth status`.

You'll then need to write `<repo>/.claude/.thk/config.json` by hand — see the schema below.

Installs are per-user, per machine.

## Usage

```
/thk <ticket-url>             # Run a ticket end-to-end (Steps 0–7)
/thk revisit <TICKET-CODE>    # Address external review feedback (Step 8)
```

Run it, step away. The Hand captures context, drafts a plan, decides whether to convene a Council meeting (and runs the `convene-meeting` skill's plan-side phase if so), publishes and updates a GitHub issue, attaches it to the source ticket, executes the plan (single-agent — the Hand writes the code itself via `execute-plan`), runs verification, **then runs a post-execution review** — either the meeting's diff-side phase if a meeting was convened, or a single Counselor sanity check if not — fixes anything flagged, and finally opens a Draft PR with a description composed by the Grand Maester. The run stops at `pr-drafted` (full happy path) or a blocking outcome (`execution-failed`, `pre-pr-review-failed`, `plan-published-review-failed`, `already-fixed`, `needs-more-info`). Read `progress.md` in the session folder when it's done; `outcome.md` is only present if the run stopped early.

**Revisit mode (`/thk revisit <TICKET>`).** After Step 7 opens a Draft PR, external reviewers — typically CodeRabbit, sometimes humans, sometimes other bots — leave feedback over the next minutes to hours. The Hand never blocks waiting; revisit is a separate entry mode that can be invoked manually, or fired by a `/schedule`-spawned background agent ~25 minutes after the PR opens. The `_revisit-pr` skill is **self-contained** — works from a fresh checkout or a different machine by rehydrating the session from the GitHub issue bundle. It pulls PR comments, triages findings (accept / defer / decline), implements accepted fixes as new commits (no force-push — Draft PRs stay append-only), re-runs verification, posts a summary comment + per-thread replies, and re-bundles the session into the GitHub issue. Idempotent across rounds — invoke again later for round N+1 against new feedback.

Re-invoking `/thk` on the same ticket is safe and idempotent — the Hand reads `progress.md`, finds the first incomplete step, and resumes from there. **Resume from a different machine** is supported too: a prior-run gate (Step 1b.5) reads the Linear ticket's Links panel for an existing thk-managed GH issue, parses the issue's hidden markers (`thk-runner-profile`, `thk-meeting`, `thk-assets-ref`), and either:

- terminates at `already-shipped` if a Draft / open / merged PR already exists, or
- **rehydrates the prior context** by fetching the assets ref and copying the bundled `context/` + `progress.md` + `runtime-profile.json` into a fresh local session, then resumes from where the prior run left off.

Net effect: thk **never** creates a duplicate GH issue or branch for the same ticket, no matter which machine you re-run from.

## Configuration — target repo

thk is **per-project** — every piece of state, config, and policy lives at `<targetRepo>/.claude/.thk/`. No home-dir files. The target repo is resolved per call:

1. `$THK_TARGET_REPO` environment variable — absolute path
2. Fallback: `$PWD`

If your launching cwd IS the target, option 1 isn't needed. To run thk against a different repo from a Claude Code session you launched elsewhere:

```bash
THK_TARGET_REPO="/Users/you/Projects/your-app" claude
```

…or just `cd ~/Projects/your-app && claude` so `$PWD` is the target. Both work; use whichever fits your workflow.

## Configuration — runtime profiles

thk resolves a runtime profile before it starts a session. The default profile is `claude_codex`, which preserves today's behavior: Claude Code runs the council and Counselor Altman wraps the Codex CLI.

Check what your machine can use:

```bash
node scripts/resolve-profile.mjs --detect
```

List built-in profiles:

```bash
node scripts/resolve-profile.mjs --list
```

Create a user config:

```bash
node scripts/resolve-profile.mjs --init --profile claude_codex
```

Profile selection order is:

1. `--profile` when calling the resolver directly
2. `$THK_PROFILE`
3. `default_profile` from config
4. Resolver recommendation based on local CLI/config signals

Config files are merged from `${CLAUDE_PLUGIN_ROOT}/config/profiles.json` (built-in), `$THK_CONFIG` (explicit override), and `<targetRepo>/.claude/.thk/config.json` (per-project). The resolver detects installed commands and auth hints, but it does not claim to verify paid subscriptions. **No home-dir state by design** — every project's resolved profile is reproducible from files committed in that project.

### Schema — `<repo>/.claude/.thk/config.json`

The repo-local config is what `install.sh` writes; you can also hand-edit it. Every key is optional except `version`.

```json
{
  "version": 1,
  "default_profile": "claude_codex",
  "sources": {
    "ticket": "linear"
  },
  "mcps": {
    "captures": ["jam", "figma", "planetscale", "notion"]
  },
  "profiles": {
    "claude_codex": { /* role overrides — model bumps, runner swaps, etc. */ }
  }
}
```

| Key | Purpose |
|-----|---------|
| `version` | Schema version. Currently `1`. |
| `default_profile` | Profile name (must exist in either the built-in `config/profiles.json` or a `profiles` block here). |
| `sources.ticket` | Which ticket source MCP to use. `"linear"` today; future sources slot in here. |
| `mcps.captures` | Optional capture MCPs to enable. Skills check this when deciding whether to dispatch the matching capture. |
| `profiles` | Per-profile role overrides — same shape as the built-ins; merges over them rather than replacing. |

`config.json` is **per-developer** (profile preferences, machine-specific). It's gitignored.

### Schema — `<repo>/.claude/.thk/policies.json` (team-shared)

Project-specific safety + workflow rules that thk consults at runtime. **This file is committed** — `install.sh` and `_scaffold-session` set up the gitignore so `.claude/.thk/policies.json` is excepted from the broad `.claude/.thk/` exclude.

```json
{
  "_meta": {
    "generatedBy": "_run-verification",
    "generatedAt": "2026-04-27T22:30:00Z",
    "inferenceSource": "lockfile=pnpm-lock.yaml + package.json scripts",
    "note": "Edit freely. thk reads this verbatim on subsequent runs. Hand-edited values are NOT overwritten — auto-bootstrap only fills missing keys."
  },
  "verification": {
    "install":   "pnpm install --frozen-lockfile",
    "typecheck": "pnpm exec tsc --noEmit",
    "build":     "pnpm run build",
    "test":      null
  },
  "planetscale": {
    "banned_tables": ["employee", "employees", "hr.employees"]
  }
}
```

| Key | Written by | Purpose |
|-----|-----------|---------|
| `verification.install` / `.typecheck` / `.build` / `.test` | `_run-verification` (auto-bootstrap) | Exact commands the verification gauntlet runs. `null` = skip explicitly. Auto-inferred from lockfile + package.json scripts on first run; team can edit and commit. |
| `planetscale.banned_tables` | `_capture-planetscale` (auto-bootstrap from AGENTS.md prose) | Tables that are off-limits to any `_capture-planetscale` query — case-insensitive match across bare / schema-qualified / aliased / subquery / CTE forms. |
| `_meta.*` | Whichever skill last wrote | Audit trail — when, why, from what source. |

**Auto-bootstrap behavior.** Skills that consult policies follow the same rule: if the relevant key is missing from `policies.json`, infer or extract it (from `package.json` for verification, from `AGENTS.md` for planetscale bans), persist the result, then proceed. Hand-edited values are never overwritten — only missing keys get filled. Subsequent runs read the file verbatim.

## Updating

```
/plugin update thk
```

Versions track git tags on this repo (`v0.1.0`, `v0.2.0`, …). Pin to a specific version by editing your local marketplace listing.

### Dev workflow — pull the latest commits without bumping the version

When you're iterating on the plugin itself and pushing changes without bumping `version` in `plugin.json` / `marketplace.json`, `/plugin update` is a no-op (version matches). Run this from the repo root instead:

```
./scripts/sync-local-plugin.sh
```

It `git fetch`es origin inside your local `~/.claude/plugins/marketplaces/thiago-tools/` clone and every live cache under `~/.claude/plugins/cache/thiago-tools/thk/*/`, hard-resets to `origin/<default-branch>`, and leaves orphaned version directories alone. If it detects that you *did* bump the version, it prints the exact `/plugin update` command to run inside Claude Code to move the install to the new version directory. Restart your Claude Code session if changes still look stale.

## Session state

Sessions live inside your target repo at `.claude/.thk/sessions/<YYYY-MM-DD_HHMMSS>_<ticket-slug>/`:

```
<target-repo>/.claude/.thk/sessions/<session-id>/
├── progress.md                  ← step tracker (resumption contract)
├── runtime-profile.json         ← selected profile snapshot
├── log.md                       ← append-only trace of every agent / skill / decision
├── worktree/                    ← code worktree on the session branch (becomes the PR)
├── assets-worktree/             ← orphan worktree on refs/thk/<TICKET-CODE> (bundle commits)
└── context/
    ├── README.md                ← entry-point index explaining the folder (read this first)
    ├── plan.md                  ← the living plan
    ├── linear/                  ← one md per ticket from the Linear MCP, full comment threads (future sources land peer folders, e.g. `jira/`)
    ├── jam/<jam-id>/            ← details, transcript, analysis, console, network, screenshots/
    ├── figma/<node-id>/         ← README.md (index), context, code/ (extracted blocks), metadata, variables, libraries, code-connect, screenshots/, html/
    ├── planetscale/             ← redacted read-only SELECT captures (produced only when the Grand Maester's judgment calls for a DB lookup)
    ├── plan-reviews/
    │   ├── round-1-plan/        ← plan-phase member reviews (only when meeting convened)
    │   ├── round-2-plan/        ← plan-phase Counselor oversight (only when meeting convened)
    │   ├── round-1-diff/        ← diff-phase member reviews (only when meeting convened, after execute)
    │   ├── round-2-diff/        ← diff-phase Counselor oversight (only when meeting convened)
    │   ├── counselor-pre-pr.md  ← single Counselor diff review (no-meeting flow's Step 6a)
    │   └── hand-decision.md     ← Hand's synthesis — Sections 1–2 (plan phase) + Sections 3–4 (diff phase)
    └── outcome.md               ← only present when the run ends on a blocking outcome
```

`install.sh` adds `.claude/.thk/` to the target repo's `.gitignore` (with explicit consent during setup) so sessions, secret keys (`.claude/.thk/keys/`), and runtime state stay out of `git status` for everyone on the team. The full `context/` folder is bundled into a commit under `.github/thk-assets/<session-id>/context/` and pushed to `refs/thk/<TICKET-CODE>` — a custom ref that lives outside branches and tags (invisible in the branch picker and tags tab, preserved forever). Every link in the issue body is a full `https://github.com/<owner>/<repo>/blob/<commit-sha>/...` URL so they resolve regardless of branch lifecycle.

### Browsing bundled assets locally

```bash
# Fetch every session's bundle into your local refs/thk/* namespace.
git fetch origin 'refs/thk/*:refs/thk/*'

# Browse one ticket's bundle.
git checkout refs/thk/ENG-10105
ls .github/thk-assets/
```

The refs never get cleaned up — months later, if a bug traces back to a decision made during the Hand's run, the full context is still pinned on origin.

## Built-in profiles

Profiles live in [`config/profiles.json`](./config/profiles.json). Each role declares a `runner`, optional `agent`, and optional `model`.

| Profile | Shape |
|---------|-------|
| `claude_codex` | Current default: Claude Code council, Codex CLI oversight through Counselor Altman |
| `claude_only` | Claude Code for every role, including a generic Counselor |
| `codex_with_opus_counselor` | Codex CLI for review roles, Claude Opus counselor when a Claude-capable host is available |
| `codex_only` | Codex CLI for model work; capture/shipping need pre-captured context or a separate adapter |
| `gemini_only` | Gemini CLI for model work through a command-template adapter |
| `portable_sequential` | Writes prompts for manual or external execution without assuming any model CLI |

Claude Code profiles can still use model overrides per role. Non-Claude runners go through [`scripts/run-profiled-role.mjs`](./scripts/run-profiled-role.mjs) for review/advisor actions. In the Claude plugin frontend, `hand.runner` is recorded for cross-frontend compatibility but cannot change the model already running `/thk`. Linear/Jam/Figma capture and GitHub/Linear shipping still depend on the Claude plugin host until standalone adapters are added for those tools.

## Contributing

The plugin is versioned through git tags. To ship a change:

1. Make the change on a branch.
2. Update `version` in `.claude-plugin/plugin.json` and the matching entry in `.claude-plugin/marketplace.json`.
3. Tag the release (`git tag v0.2.0 && git push --tags`).
4. Teammates pick it up with `/plugin update thk`.
