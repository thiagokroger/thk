# thk — The Hand of the King — Architecture

A Game-of-Thrones-inspired workflow for end-to-end delivery of engineering tickets. The Hand runs the realm: captures every piece of context, drafts a plan, and — at the Hand's discretion — summons a cabinet of specialist reviewers (the **Small Council**) to deliberate before anything ships. The Hand routes per ticket: trivial tickets ship straight from the published plan; complex ones get the Council. The Council deliberation procedure lives in its own skill (`convene-meeting`) so the top-level `thk` skill stays a slim router.

> This is the design/architecture reference. The canonical runtime behavior lives in `skills/thk/SKILL.md` (loaded when a user invokes `/thk`). For install and day-to-day usage, see the top-level `README.md`.

## Public API

This plugin exposes exactly **one** user-facing skill: `/thk` (the Hand of the King). Everything else is internal:

- `skills/thk/SKILL.md` — the Hand's runtime contract; routes the flow.
- `skills/_convene-meeting/SKILL.md` — the Council deliberation procedure (two phases: plan-side and diff-side), invoked by the Hand when a ticket warrants formal review.
- `skills/<action>/SKILL.md` — 26 action skills invoked only by the Hand and its council members via the `Skill` tool. They are discoverable by Claude Code but exist to be called through the Hand's flow.
- `agents/*.md` — Claude Code subagent definitions dispatched only by the Hand when the selected profile uses `claude-code`.
- `config/profiles.json` — built-in runtime profiles mapping roles to runners, agents, and models.
- `scripts/resolve-profile.mjs` — profile resolver and local runner detector.
- `scripts/run-profiled-role.mjs` — external runner bridge for review/advisor roles.
- `scripts/log.sh` — shared logger; every dispatch writes to the session log.

Consumers depend on the single entrypoint — never on any of its internals. When the plugin evolves (sub-skills added, agents renamed, scripts refactored), the public contract — `/thk <ticket-url>` — stays stable.

**The host is Claude Code. Period.** thk is a Claude Code plugin and depends on Claude Code's `Agent` dispatch, `Skill` invocation, MCP runtime, and slash-command surface. Standalone Codex / Gemini / Cursor hosts are out of scope today — the `portable_sequential` profile gestures at a future where the Hand could emit prompts for an external CLI to execute one at a time, but that's not built.

What *is* pluggable, inside the Claude Code host:

- **Ticket source MCP.** Linear today (via `capture-linear`); Jira or another tracker plugs in as a sibling `capture-<source>` skill that writes ticket markdown to a peer folder under `<contextDir>/`. The rest of the flow — plan, Council, execute, PR — doesn't know which tracker the ticket came from.
- **Council member + Counselor runners.** Each role's runner is set per-profile in `config/profiles.json`: Claude, Codex CLI, or Gemini CLI. Reviews and advisor passes can fan out to whichever model the team prefers without touching the Hand.

The Hand itself is not agnostic and isn't trying to be.

**Runtime paths:** once the plugin is installed, Claude Code auto-discovers `skills/` and `agents/` at the plugin root. The plugin's on-disk location is exposed to every skill/agent through the `${CLAUDE_PLUGIN_ROOT}` environment variable — that's the only path any internal script should reference. Session state lives separately, under `<targetRepo>/.thk/sessions/`. Each session also persists the resolved runtime profile at `runtime-profile.json` so a resumed run does not silently change model assignments.

## The metaphor

In Westeros, the Hand of the King runs the realm with a cabinet of advisors, each holding a distinct office. The user is the **King** — goal owner, final call. The **Hand** is the protagonist of this plugin; the **Small Council** is the deliberative body the Hand may summon. The selected runtime profile decides which model runner plays the Hand and each council role. In the current Claude plugin frontend, Claude Code still hosts orchestration and MCP capture, while Codex/Gemini/other CLIs can be consulted through profile adapters.

## The cast

### Council roles

| Role | Member | Default `claude_codex` runner | Responsibility |
|------|--------|-------------------------------|----------------|
| Orchestrator | **Hand of the King** (this skill) | Claude Opus | Holds the definition-of-done, routes work, synthesizes verdicts, owns the `hand-decision.md` audit trail |
| Intelligence | **Master of Whisperers** | Claude Sonnet | URL-driven captures — Linear + Jam + Figma — all read-only, all into `context/`. Does **not** touch the database |
| Scholar | **Grand Maester** | Claude Opus | Root-cause investigation, code-correctness review, and **plan review against Notion engineering docs + git history** (`convene-meeting` Step 1). Holds the PlanetScale MCP keys: runs targeted read-only SELECTs on his own judgment when a ticket or plan hinges on a specific record's state |
| Enforcer | **Master of Laws** | Claude Opus | Type-check, lint, build verification, business rules, and **plan review against business rules + language conventions** (`convene-meeting` Step 1) |
| Red team | **Lord Commander of the Kingsguard** | Claude Opus | Adversarial security review of the diff AND **plan-level security review** across six lenses (`convene-meeting` Step 1) |
| Budget | **Master of Coin** | Claude Opus | Effort estimate, scope drift, tech-debt ticket drafts, and **quick-fix / tech-debt carveout review** at plan time (`convene-meeting` Step 1) |
| Shipwright | **Master of Ships** | Claude Haiku | Git plumbing — worktrees, branches, commits, PRs, GitHub issue publish / update (with full `context/` bundling), and attaching the GitHub issue as a linked resource on the primary ticket (currently via the Linear MCP) after the council approves the plan |
| Oversight | **Counselor** | Claude Sonnet wrapper around Codex CLI | External or independent oversight after the Hand has synthesized the first council round |

### Runtime profiles

Profiles map stable roles to concrete runners and model IDs. Built-ins live in `config/profiles.json`; user and repo configs can add or override profiles.

| Profile | Shape |
|---------|-------|
| `claude_codex` | Current default: Claude Code council, Codex CLI oversight through Counselor Altman |
| `claude_only` | Claude Code for every role, including a generic Counselor |
| `codex_with_opus_counselor` | Codex CLI for review roles, Claude Opus counselor when a Claude-capable host is available |
| `codex_only` | Codex CLI for model work; capture/shipping need pre-captured context or another adapter |
| `gemini_only` | Gemini CLI for model work through command-template args |
| `portable_sequential` | No model runner assumed; prompts are emitted for manual or external execution |

The resolver detects installed CLIs and auth hints, but it does not assert subscription status. Runners beyond `claude-code` are intentionally command-template based so teams can add Cursor, Gemini, OpenAI, Anthropic, or local-model wrappers without changing the council roles. In the Claude plugin frontend, `hand.runner` is recorded for cross-frontend compatibility; it does not change the model already executing `/thk`.

## How it works

Execution is a **single call**, **resumable**, and terminates at one of several outcomes: PR drafted (full happy path), execution failed, plan published but review failed (degraded handoff), already fixed, or needs more info. The King invokes `/thk <ticket-url>` and walks away; there is no mid-run interaction. The Hand is a **state-aware entry point** — re-invocation on the same ticket reads `progress.md`, identifies the first incomplete step, and picks up from there.

Current flow:

- **Step 1 — Capture**: Master of Whisperers exhaustively downloads URL-driven context via per-MCP capture skills into `context/linear/`, `context/jam/`, and `context/figma/`. Database captures (`context/planetscale/`) are **not** part of Step 1 — they are a judgment call the Grand Maester makes inside `convene-meeting` if the ticket or plan hinges on a specific record's state.
- **Decision gate**: the Hand inspects the captured context + code. If the fix is already present → write `context/outcome.md` (`already-fixed`) and stop. If critical info is missing → `context/outcome.md` (`needs-more-info`) and stop. Otherwise proceed.
- **Step 2a — Plan draft**: the Hand writes `context/plan.md` — a living document designed to be executable from the published issue + the repo alone.
- **Step 2b — Publish plan**: Master of Ships publishes the plan as a self-contained GitHub issue (via `publish-plan-to-github`) — the entire `context/` folder is committed to `.github/thk-assets/<session-id>/context/` inside the session's **assets worktree** and pushed to `refs/thk/<TICKET-CODE>`, a custom ref that lives outside `refs/heads/*` and `refs/tags/*` (invisible in the branch picker and tags tab, but pinned forever). The primary ticket is inlined in the issue body; every asset link uses the commit SHA so URLs survive forever regardless of branch lifecycle. A downstream agent or human developer needs only the issue URL + `git clone` (plus `git fetch origin 'refs/thk/*:refs/thk/*'` if they want to browse the bundle locally) to pick up from here.
- **Step 3 — Convene a meeting? (plan side)**: the meeting decision is **the Grand Maester's**, not a heuristic. The Hand dispatches `Agent(grand-maester, action: assess-meeting-need)` which reads the plan, scans the codebase + git history for similar prior efforts, weighs surface signals (auth-surface, payment-surface, schema-change, dependency-change, multi-file-scope, etc.), and returns a citation-grounded verdict — `{ recommend_meeting, weight_score: 1-10, evidence: { similar_past_prs, history_density, revert_or_hotfix_count, weight_signals }, reasoning }`. If `recommend_meeting: true`, the Hand invokes `_convene-meeting` with `phase: "plan"`: four profiled member reviews of `plan.md` under `plan-reviews/round-1-plan/` (parallel when supported), Hand synthesis + revision + a first `update-github-issue` push, profiled Counselor oversight under `plan-reviews/round-2-plan/`, second Hand synthesis + final `update-github-issue` push. Hand decisions across both phases live in `plan-reviews/hand-decision.md`. The decision is all-or-nothing — committing to a meeting also commits to running its diff-side phase at Step 6. Project policy can override the Grand Maester via `policies.review.meeting_decision: "always" | "never"`; the default `"auto"` consults him.
- **Step 4 — Announce**: Master of Ships attaches the GitHub issue URL to the primary ticket's Links panel (Linear-MCP-specific behavior today) with the title `Hand of the King — <TICKET-CODE>` so the assigner sees a clickable resource card where cross-references belong — no activity-feed comment. Failure to attach is non-blocking since the GitHub issue is already the authoritative artifact.
- **Step 5 — Execute**: the Hand invokes `_execute-plan` — single-agent, no fan-out. The skill applies the Files-to-modify/add/delete edits per the plan, updates tests per the plan's Tests section, dispatches Master of Laws (`run-verification`) for `tsc --noEmit && pnpm run build`, and fixes-and-retries on failure (capped, default 3 iterations). On unrecoverable failure, the run terminates at `execution-failed` with the published issue + ticket announce as the durable artifacts.
- **Step 6 — Post-execution review**: branches on the meeting decision. (a) **No-meeting flow**: the Counselor (single advisor — Codex CLI in `claude_codex`, Claude in `claude_only`) reviews the diff with one question — "was the plan executed well?". The Counselor pass is **policy-gated** by `policies.review.counselor_on_simple_path` (default `true`); when enabled, it provides foreign-perspective oversight on simple tickets via a different model than the Hand's. The Hand fixes any flagged issues (capped at 2 iterations), then `update-github-issue` bundles the new `counselor-pre-pr.md`. When the policy is `false`, Step 6a is skipped entirely (rare; usually only for Claude-only profiles where the Counselor would be Claude-reviewing-Claude). (b) **Meeting flow**: the Hand invokes `_convene-meeting` with `phase: "diff"` — four diff-side member reviews (`review-correctness`, `review-against-rules`, `red-team-review`, `scope-check`) under `plan-reviews/round-1-diff/`, Hand fixes (capped), Counselor oversight under `plan-reviews/round-2-diff/`, two `update-github-issue` pushes. Both paths populate `hand-decision.md` Sections 3–4 (or just append Counselor notes for the no-meeting path). On unrecoverable failure either way, the run terminates at `pre-pr-review-failed`.
- **Step 7 — Open Draft PR + auto-schedule revisit**: Master of Ships commits the changes (`commit-changes`); Grand Maester drafts the PR description by reading the plan + the actual `git diff` + the GitHub issue + the source ticket (`draft-pr-description`); Master of Ships pushes the branch and opens a Draft PR with `--draft` (`push-and-open-pr`). **No Linear comment is posted** — the GitHub issue (already in the Linear ticket's Links panel from Step 4) carries the PR URL, so humans find it via Linear → GH issue → PR. Linear @-mentions are reserved for the `needs-more-info` outcome (the only path where the Hand pings humans). After the PR opens, the Hand auto-schedules a `/thk revisit <TICKET>` cron job for T+`policies.review.auto_revisit_after_minutes` (default 30) via `CronCreate` — no user prompt, no follow-up offer. Set the policy to `null` to disable. The run terminates at `pr-drafted` — the Draft PR is the implementation handoff to a human reviewer.
- **Step 8 — Revisit PR (separate entry mode)**: invoked via `/thk revisit <TICKET>`, fired automatically by the cron job Step 7 scheduled (or manually if needed). The Hand never blocks waiting for reviews after Step 7 — Step 8 is its own entry point. The skill is `_revisit-pr` and is **self-contained**: it detects warm vs cold regime (cold = nothing local for the ticket) and rehydrates from the GitHub issue bundle when needed via Master of Ships' `rehydrate-from-issue`. It pulls PR feedback (`gh pr view`/`gh api .../pulls/<n>/comments`), triages findings into accept/defer/decline (Hand drives; ad-hoc consults to Grand Maester or Lord Commander when uncertain), implements accepted findings as new commits on the PR branch, re-runs verification, posts a summary comment + per-thread replies via `post-revisit-summary`, and re-bundles the session into the GitHub issue. Force-push is forbidden — Draft PRs stay append-only so reviewers can see what response each comment got. Step 8 is idempotent across rounds — invoke again later for round N+1 against new feedback.

Throughout *every* step, the Hand can dispatch any **single** council member ad-hoc — Grand Maester for a database lookup, Master of Laws for a quick rules sanity check, Lord Commander for a focused security read on one risky file. These ad-hoc consults are routine dispatches, not meeting rounds; they don't require Step 3's meeting decision. The Counselor is the exception: it's only dispatched as the closer of a deliberation (Step 3 plan-phase Counselor, Step 6a no-meeting Counselor, or Step 6b diff-phase Counselor).

Progress is tracked in `progress.md` at the session root. If the call crashes or times out, re-invoking on the same ticket resumes from the first incomplete step. Re-invocations after a terminal status (`pr-drafted`, `execution-failed`, `pre-pr-review-failed`, etc.) mint a new session if needed; the Hand never silently reuses a finished run.

**Resume from a different machine + prior-run gate.** The published issue carries hidden HTML markers — `thk-assets-ref`, `thk-runner-profile`, and (after Step 3) `thk-meeting`. A `/thk` invocation on a fresh machine (or after a local cleanup) hits Step 1b.5, which reads the Linear ticket's Links panel for an existing `Hand of the King — <TICKET-CODE>` link. If found, it parses the markers, checks PR state via `gh pr list --search "head:<branchName>"`, and decides:

- **Draft / open / merged PR** → terminate at `already-shipped`, point at the existing artifacts, stop.
- **Closed unmerged PR** → fetch the assets ref, copy the bundled `context/` + `session-progress.md` + `session-runtime-profile.json` into a freshly-scaffolded local session, mint a v2 attempt on `<branchName>-v2`.
- **No PR found** → rehydrate as above and resume from the rehydrated `progress.md`'s first incomplete step. Reuses the existing GH issue (no duplicate).

Both `_publish-plan-to-github` and `_update-github-issue` bundle the session's `progress.md` and `runtime-profile.json` alongside `context/` so rehydration reads exact prior state, not inferences. Net effect: thk **never** creates a duplicate GH issue or branch for the same ticket regardless of which machine the run resumes on.

**Not yet in scope** (future iterations of the skill):
- Auto-mark the Draft PR as ready-for-review when verification passes in CI as well as locally.

Full state machine lives in `SKILL.md` at the package root.

## Sessions

Every task opens a **session folder** at `<targetRepo>/.thk/sessions/<YYYY-MM-DD_HHMMSS>_<slug>/`:

```
<targetRepo>/.thk/sessions/2026-04-22_143000_eng-10105/
├── worktree/         ← code worktree on the session branch (becomes the PR)
├── assets-worktree/  ← orphan worktree backing refs/thk/<TICKET-CODE> (bundle commits)
└── context/          ← shared dossier — every agent reads from here
```

`context/` is a stable, CLI-agnostic contract. Master of Whisperers organizes captured intelligence into per-MCP subfolders. The living plan lives at `context/plan.md`. The council's deliberation output lives under `context/plan-reviews/`, split into three rounds: Round 1 (four profiled member reviews), Round 2 (Counselor oversight), and Round 3 (the Hand's synthesis — `hand-decision.md`, one section per review round). Other synthesized artifacts (root-cause analysis, review brief) live at the root of `context/`. An index at `context/README.md` (written by `scaffold-session`) explains the folder to downstream agents.

```
<targetRepo>/.thk/sessions/<session-id>/
├── progress.md              ← step tracker (resumption contract)
├── runtime-profile.json     ← selected profile snapshot for deterministic resume
├── worktree/                ← code worktree on the session branch
├── assets-worktree/         ← orphan worktree on refs/thk/<TICKET-CODE>
└── context/
    ├── README.md            ← entry-point index for downstream agents
    ├── plan.md              ← the living plan (written during Step 2a, revised in Step 3)
    ├── linear/              ← one md file per ticket (primary + linked/parent/sub/related)
    ├── jam/<jam-id>/        ← details, transcript, analysis, console, network, screenshots/
    ├── figma/<node-id>/     ← README.md (index), context, code/ (extracted blocks), metadata, variables, libraries, code-connect, screenshots/, html/
    ├── planetscale/         ← read-only DB query captures (when applicable)
    ├── plan-reviews/        ← Council deliberation (meeting flow) + post-execution review
    │   ├── round-1-plan/    ← plan-phase member reviews (only when meeting convened)
    │   │   ├── grand-maester.md
    │   │   ├── master-of-laws.md
    │   │   ├── lord-commander.md
    │   │   └── master-of-coin.md
    │   ├── round-2-plan/    ← plan-phase Counselor oversight (only when meeting convened)
    │   │   └── <profile counselor artifact>
    │   ├── round-1-diff/    ← diff-phase member reviews (only when meeting convened, after Step 5)
    │   │   ├── grand-maester.md
    │   │   ├── master-of-laws.md
    │   │   ├── lord-commander.md
    │   │   └── master-of-coin.md
    │   ├── round-2-diff/    ← diff-phase Counselor oversight (only when meeting convened)
    │   │   └── <profile counselor artifact>
    │   ├── counselor-pre-pr.md  ← single Counselor diff review (no-meeting flow's Step 6a)
    │   └── hand-decision.md ← Hand's synthesis. Sections 1–2 = plan-phase verdicts; Sections 3–4 = diff-phase verdicts (or Counselor pre-PR notes for no-meeting flow).
    └── outcome.md           ← only when the run ends on a blocking outcome
```

The capture is exhaustive — every comment, every screenshot, every log. The intent is that **any downstream consumer** — another AI agent (Codex, Gemini, Grok), a human developer on a different machine, or a future maintainer opening the issue weeks from now — can work from the published GitHub issue + `git clone` alone, with no MCP connections, no Linear credentials, and no local session folder. `publish-plan-to-github` and `update-github-issue` enforce this by committing the entire `context/` folder into `.github/thk-assets/<session-id>/context/` inside the session's assets worktree and pushing to `refs/thk/<TICKET-CODE>`. New advisors plug in the same way.

### Why a custom ref, not a branch or tag

Bundle commits go to `refs/thk/<TICKET-CODE>` — a custom ref namespace outside both `refs/heads/*` (branches) and `refs/tags/*` (tags). The tradeoffs this solves:

- **No branch-listing clutter.** Doesn't appear in the GitHub branch picker when opening PRs, doesn't pollute `git branch -a`, doesn't pile up as stale branches.
- **Tag namespace stays free for releases.** Repos that tag every release (`2026.4.24`, `2026.4.25`, ...) would drown in thk tags.
- **Pinned forever.** It's a real ref — GitHub's garbage collector won't touch commits reachable from it. No cleanup workflow needed.
- **Fetchable when needed.** `git fetch origin 'refs/thk/*:refs/thk/*'` pulls every session's bundle locally; `git checkout refs/thk/<TICKET-CODE>` browses one.

The tradeoff: GitHub's `/blob/<ref>/...` URL router only resolves refs under `refs/heads/*` and `refs/tags/*`, so issue body links must use the **commit SHA** rather than the ref name. Commit SHAs in `/blob/<SHA>/...` URLs are fully supported and resolve forever because the ref keeps the commit pinned.

**Issue-body links are full GitHub URLs using commit SHAs.** Every link uses `https://github.com/<owner>/<repo>/blob/<assetsSha>/.github/thk-assets/<session-id>/<path>` (or `/raw/` for inline images on public repos). Leading-slash paths like `/.github/...` are not URLs and GitHub's markdown renderer won't treat them as links. For private repos, screenshots are rendered as markdown links rather than `![]()` embeds because GitHub's camo proxy cannot fetch raw bytes from private repos. The `publish-plan-to-github` and `update-github-issue` skills both verify that every link in the issue body is a real `https://` URL before returning success — a leading-slash value fails the self-contained contract. Each issue body also carries a hidden `<!-- thk-assets-ref: refs/thk/<TICKET-CODE> -->` marker so future tooling can discover the ref without parsing URLs.

## Folder layout

```
${CLAUDE_PLUGIN_ROOT}/
├── README.md
├── config/
│   └── profiles.json                    ← built-in role/runner/model profiles
├── scripts/
│   ├── resolve-profile.mjs              ← merges config + detects local runners
│   ├── run-profiled-role.mjs            ← external CLI bridge for review/advisor roles
│   └── log.sh                           ← shared session logger
├── skills/
│   ├── thk/                            ← the Hand's persona + single-call flow (/thk); routes the run — this is the only user-facing skill
│   ├── _convene-meeting/          ← Council deliberation procedure invoked when the Hand decides a ticket warrants review
│   ├── _execute-plan/                  ← single-agent implementation: applies the plan's edits, dispatches verification, fixes-and-retries
│   ├── _draft-pr-description/          ← Grand Maester action — reads plan + diff + issue + ticket, returns { title, body }
│   ├── _capture-linear/                ← Linear MCP capture
│   ├── _capture-jam/                   ← Jam MCP capture
│   ├── _capture-figma/                 ← Figma MCP capture
│   ├── _capture-planetscale/           ← read-only DB query capture (PlanetScale MCP) — owned by Grand Maester, invoked as a sub-skill on his judgment
│   ├── _review-plan-history/           ← Grand Maester plan review (Notion + git history)
│   ├── _review-plan-rules/             ← Master of Laws plan review (business + language rules)
│   ├── _review-plan-security/          ← Lord Commander plan review (six security lenses)
│   ├── _review-plan-cost/              ← Master of Coin plan review (quick-fix / tech-debt carveout)
│   ├── _resolve-base-branch/           ← scan ticket for PR-preview URLs
│   ├── _scaffold-session/              ← create session folder + worktree + progress.md
│   ├── _commit-changes/                ← stage + commit by explicit path
│   ├── _push-and-open-pr/              ← push branch + gh pr create (--draft when requested); does NOT post Linear comments
│   ├── _publish-plan-to-github/        ← first-time publish of plan.md as a GH issue
│   ├── _update-github-issue/           ← push revised plan.md back to the same issue
│   ├── _announce-plan-completion/      ← attach the GitHub issue as a linked resource on the source ticket via the Linear MCP today (Step 4)
│   ├── _create-linear-followup-ticket/ ← Linear MCP issue creation
│   ├── _cleanup-session/               ← git worktree remove + optional rm -rf session
│   ├── _investigate-root-cause/        ← writes root-cause-analysis.md
│   ├── _review-correctness/            ← diff review for correctness + edge cases
│   ├── _review-against-rules/          ← diff review against tsc / lint / Notion rules
│   ├── _run-verification/              ← pnpm i && tsc && build
│   ├── _red-team-review/               ← adversarial diff review (6 lenses)
│   ├── _estimate-effort/               ← upfront t-shirt estimate
│   ├── _scope-check/                   ← mid-implementation drift check
│   ├── _draft-techdebt-ticket/         ← body for a carveout follow-up ticket
│   └── _codex-review/                  ← Codex CLI wrapper (plan/correctness/review/red-team/free)
│
│   (Underscore prefix marks skills as internal — invoked by the Hand or council
│   agents only, not directly by the user. Claude Code still surfaces them in the
│   slash menu — the underscore is convention, not a hide flag.)
└── agents/
    ├── master-of-whisperers.md          ← action-dispatcher for capture-* (linear/jam/figma) — URL-driven sources only
    ├── master-of-ships.md               ← action-dispatcher for git/GH/Linear plumbing (scaffold, commit, push, publish, update-issue, announce-completion, followup-ticket, cleanup)
    ├── grand-maester.md                 ← action-dispatcher for investigate-root-cause, review-correctness, review-plan-history
    ├── master-of-laws.md                ← action-dispatcher for review-against-rules, run-verification, review-plan-rules
    ├── lord-commander.md                ← action-dispatcher for red-team-review, review-plan-security
    ├── master-of-coin.md                ← action-dispatcher for estimate / scope / tech-debt / review-plan-cost
    ├── counselor-altman.md              ← default Codex-backed counselor action-dispatcher
    └── counselor.md                     ← generic Claude counselor for non-Codex Claude profiles
```

### The action pattern

Every council member is a thin **action-dispatcher**. When a role uses `claude-code`, the Hand invokes that member via the `Agent` tool with a prompt carrying `action: "<short-name>"` plus args; the member routes to the matching skill and wraps the envelope. When a role uses an external runner, the Hand calls `scripts/run-profiled-role.mjs` with the same action and args so the review still produces the same markdown artifact and envelope shape.

**Action names are the stable contract.** They stay short (`capture-linear`, `run-verification`, `commit-changes`, etc.) — without the underscore prefix that the underlying skill folders carry. Each agent's `Action → Skill` table is the indirection: `capture-linear` action routes to the `_capture-linear` skill on disk. Callers never type the underscore form; only the agent (or the resolver script's `actionSkills` map) crosses that boundary.

| Agent | Actions |
|-------|---------|
| Hand (the Hand drives `execute-plan` itself rather than dispatching) | `execute-plan` (sole agent — no fan-out) |
| Master of Whisperers | `capture-linear`, `capture-jam`, `capture-figma` |
| Master of Ships | `resolve-base-branch`, `scaffold-session`, `commit-changes`, `push-and-open-pr` (accepts pre-composed `prTitle` / `prBody`, supports `draft: true`), `publish-plan-to-github`, `update-github-issue`, `announce-plan-completion`, `create-linear-followup-ticket`, `cleanup-session` |
| Grand Maester | `investigate-root-cause`, `review-correctness`, `review-plan-history`, `draft-pr-description` |
| Master of Laws | `review-against-rules`, `run-verification`, `review-plan-rules` |
| Lord Commander | `red-team-review`, `review-plan-security` |
| Master of Coin | `estimate-effort`, `scope-check`, `draft-techdebt-ticket`, `review-plan-cost` |
| Counselor | `ask`, `review-plan`, `review-pr`, `red-team` |

Adding capability = add a skill + list it in the relevant agent's action table. Adding a new external **URL-driven** source (Notion links, GitHub URLs, another URL-addressed archive, …) = add a `capture-*` skill and give it to Whisperers. Adding a new **judgment-driven** source (something where the decision to fetch is based on reasoning, not pattern matching) = give the skill to the council member whose role covers that reasoning — the way PlanetScale is the Grand Maester's.

**Database captures are judgment-driven, not URL-driven.** Unlike Jam / Figma (discovered as links in the source ticket and fetched every time they appear), DB captures are the **Grand Maester's** call, made during his `convene-meeting` review when he recognizes that a ticket or plan hinges on a specific record's state — a named user, an order ID, a subscription, a session — and the code path alone can't answer whether it's a data issue or a logic issue. He invokes the `capture-planetscale` sub-skill via `Skill` with a narrow SELECT (targeted WHERE, minimal columns, explicit `LIMIT`, one-line `purpose`). The sub-skill enforces a universal read-only safety gate (single-statement SELECT, banned-keywords list, auto-`LIMIT 100` if absent) and auto-redacts credential-like columns (`password*`, `*_hash`, `token*`, `secret*`, etc.). **Project-specific table bans (e.g. HR / PII tables that are off-limits regardless of purpose) live in the target repo's `AGENTS.md` or `.thk/policies.json` — thk ships no hardcoded list, so the rule is whatever each project declares.** The Hand does not plan, request, or dispatch DB queries — ownership lives fully with the Grand Maester.

### Parallelism via swarms

When the selected profile uses `claude-code` for the relevant roles, one `Agent` tool call = one subagent instance, so the Hand can dispatch many instances of the **same** agent in parallel — or many different agents at once. Two places the default profile exploits this:

- **Whisperer swarm (Step 1d)** — one Whisperer per URL (Jam / Figma). All URL-driven captures run concurrently.
- **Council review swarm (`convene-meeting` Step 1)** — Grand Maester, Master of Laws, Lord Commander, and Master of Coin all dispatched in a single message when the profile supports parallel Claude agents, each reviewing the same plan through a different lens. Sequential profiles keep the same artifact contract.

The Counselor runs sequentially after the Hand's Round 1 synthesis, not in the council swarm — the oversight pass needs the Hand's decisions as input. That's a deliberate ordering, not a parallelism gap.

This is how the default flow gets real parallelism without needing sub-sub-agents (which Claude Code doesn't allow anyway).

**Repo hygiene:**
- `${CLAUDE_PLUGIN_ROOT}/` → committed (shared team config)
- `<targetRepo>/.thk/sessions/` → gitignored (per-developer, ephemeral, contains secrets and worktrees)

## Delegation contract

Every dispatch from the Hand to a council member passes:

- `workdir` — absolute path to the session's worktree
- `contextDir` — absolute path to `<targetRepo>/.thk/sessions/<session-id>/context/`
- Mode-specific inputs (see each agent's file)

Every member returns a short structured verdict:

```
{ approved: boolean, issues: [...], notes: string, artifacts?: {...} }
```

The Hand does not need raw external-runner transcripts, raw Jam video transcripts, or full build logs. Members do the heavy lifting with their own context windows; the Hand coordinates with clean, summarized envelopes and stores longer artifacts under `context/`.

## Profile Resolution

`scripts/resolve-profile.mjs` builds the runtime profile from:

1. `${CLAUDE_PLUGIN_ROOT}/config/profiles.json` (built-in defaults)
2. `$THK_CONFIG`, if set (explicit override — typically per-shell or per-CI-run)
3. `<targetRepo>/.thk/config.json` (committed per-project)

thk is per-project — there's no home-dir state. A teammate's machine resolves the same profile from the same files because they live in the repo.

Profile selection precedence is explicit CLI `--profile`, then `$THK_PROFILE`, then `default_profile`, then the resolver's recommendation from local command/config signals.

The resolved JSON is persisted to `<sessionPath>/runtime-profile.json`. On resume, the Hand reuses that snapshot instead of re-resolving. This prevents a long-running session from switching models because the user's global config changed overnight.

For Claude Code agents, model precedence is: profile role model override -> agent frontmatter pin -> inherited parent model. The frontmatter pins remain as safe defaults, but profiles are the normal way to change model assignments now.

## Extending the council

Adding a new **runner or advisor**:

1. Add or override a profile entry in `config/profiles.json` or a user/repo config.
2. For a Claude-hosted advisor, create `agents/<name>.md` and point the `counselor.agent` field at it.
3. For an external CLI, set the role `runner` plus either a built-in adapter (`codex-cli`, `gemini-cli`) or `command`/`args` with `{{prompt}}`.
4. The runner must read the session's `context/` folder, return `{ approved, issues[], notes }` or equivalent prose the Hand can interpret, and own its timeout/retry behavior.

Adding a new **council member** (a new office) is a larger architectural change — those six roles are intentionally stable. Advisors are the lightweight extension point.

## Per-agent project instructions

Each council member has a markdown file at `<repo>/.thk/agents/<member>.md` where the team can drop project-specific guidance. `_scaffold-session` bootstraps seven placeholder files on first run — one per member, each containing a single HTML comment explaining what kind of guidance fits there. Agents read their file at the start of every dispatch and forward any non-comment content to the dispatched skill under `projectInstructions:` so the guidance reaches the layer that can act on it.

The mechanism is a per-repo extension surface that complements the global agent definitions in `agents/*.md` (the plugin's defaults) and `policies.json` (structured rules). Three escape hatches with three audiences:

- `agents/*.md` (this repo) — defaults applied to every project, edited by thk maintainers.
- `<repo>/.thk/policies.json` — structured rules (banned tables, verification commands, revisit thresholds), edited by repo teams.
- `<repo>/.thk/agents/<member>.md` — freeform per-agent prose, edited by repo teams.

`policies.json` is for facts the agent must enforce verbatim; the per-agent markdown file is for nuance, conventions, and judgment calls that don't fit a structured schema. Agents apply both alongside their built-in defaults.

The placeholder files are team-shared. `_scaffold-session` writes a denylist-style `.gitignore` block (`.thk/sessions/`, `.thk/keys/`, `.thk/config.json`) so the transient and per-developer pieces stay out of git while `policies.json` and `agents/*.md` commit naturally — no negation patterns required. Agents never overwrite a user-edited file; the bootstrap is one-time per fresh session-scaffold.

## Running thk from a different repo

thk is repo-agnostic *as a skill package* — the skills reference `workdir` as an argument, with no hard-coded paths. But the MCP servers (Linear, Jam, Figma, PlanetScale, GitHub, Notion) are defined at the launching-Claude-Code level, so if a team uses Jira instead of Linear, the `capture-linear` skill won't apply — a `capture-jira` skill would need to exist first.

For the repo location itself: when Claude Code is launched from one directory but you want the Hand to operate on a different repo, it resolves `targetRepo` at step 0 in this order (first hit wins):

1. `$THK_TARGET_REPO` environment variable (absolute path).
2. Fallback: `$PWD` (Claude's cwd when `/thk` was invoked).

There's no home-dir workspace pointer by design — thk is per-project. Either launch Claude Code from inside the target repo (`$PWD` resolution) or set `THK_TARGET_REPO` for the session.

The resolved `targetRepo` is passed as `workdir` to every dispatch. It is also passed to `resolve-profile.mjs` so the repo-local profile config at `<targetRepo>/.thk/config.json` participates in resolution. See SKILL.md § Workspace and profile resolution for the definitive spec.

## Logging

Every session keeps an **append-only log** at `<targetRepo>/.thk/sessions/<session-id>/log.md`. The Hand and every council member append entries per meaningful interaction — `step-start`, `step-done`, `dispatch`, `skill-invoke`, `dispatch-detail`, `skill-return`, `decision`, `error`. When anything goes wrong, the log is the first place to look; at session end `publish-plan-to-github` / `update-github-issue` bundle `log.md` as `session-log.md` alongside the committed context, so the GitHub issue carries the full debug trail.

The logger lives at `${CLAUDE_PLUGIN_ROOT}/scripts/log.sh`:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root|contextDir|worktree> <actor> <event> <message>
```

The first argument accepts the session root, the contextDir, or the worktree — the script normalizes. Short appends are atomic on POSIX so parallel sub-agents can all write without a mutex. The log is created on first call.

### `dispatch-detail` — foldable history of what each subagent did

Most events are single-line. `dispatch-detail` is the exception: it carries a multi-line markdown blockquote body summarizing what a skill DID inside (every distinct MCP call, every Bash invocation, every Write/Edit). Read-only actions (Read / Grep / Glob) are noise — skip them.

The body is read from stdin, indented one level (`> `) so it renders as a foldable blockquote under the event header in markdown viewers. The King can scan the headers; expand a `dispatch-detail` to see what the skill actually did.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh <session-root> <actor> dispatch-detail "<skill> <1-line args>" <<'BODY'
tool: mcp__<name> (<args>) → <short result>
bash: <one-liner> → <short result>
write: <comma-separated file paths>
BODY
```

**Three-entry pattern.** Every skill dispatch by a council member produces three log entries:

1. `skill-invoke` — single-line header: which skill, which args
2. `dispatch-detail` — multi-line body: what the skill did
3. `skill-return` — single-line footer: outcome (`approved=<bool> <one-line>` or `error: <reason>`)

The Hand drives directly during `_execute-plan` and follows the same pattern with actor `hand`. Each agent's Rules entry has the exact incantations.

The Hand's SKILL.md has the full logging contract at step granularity. Each council member's agent file has a Rules entry covering their dispatches.

## Cardinal rules

- No change ships without the verification gauntlet passing — `tsc --noEmit && pnpm run build` must be green before the Draft PR is opened. Council review is a Hand-driven decision per ticket; verification is unconditional.
- The Hand never silently ignores dissent — every reviewer's concern gets a verdict (accept / reject / defer) with reasoning in `hand-decision.md`.
- External advisors are advisory, not council members — they inform but do not vote.
- The `context/` folder is the single source of truth; everyone reads from the same dossier.
- **The GitHub issue is the durable revision log.** Substantive plan changes trigger one `update-github-issue` call — not per-review, not batched silently. Each `update-github-issue` call is one row of the issue's edit history that future maintainers will read to understand how the plan evolved.
- **The published issue is a complete handoff.** `publish-plan-to-github` and `update-github-issue` bundle the entire `context/` folder into the repo. A reader who lands on the issue URL with only `git clone` must be able to execute the plan — no MCP, no Linear access, no local session folder.
- **Execution is single-agent.** The Hand drives `execute-plan` itself; no fan-out to sub-agents writing files in parallel. The merge-conflict surface and re-derivation cost outweigh the wall-clock savings for typical tickets, and the Hand already carries the mental model from drafting the plan.
- **PR descriptions are composed by Grand Maester, not the plumbing skill.** `push-and-open-pr` accepts `prTitle` / `prBody` from the caller and refuses to invent text. The scholar role owns synthesis; the plumbing role owns execution.
- **Draft PRs stay Draft.** The Hand never marks a PR ready-for-review on its own — that's the human reviewer's call.
- The King has the final word.
