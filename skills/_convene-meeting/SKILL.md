---
name: _convene-meeting
description: Convene a formal Small Council meeting to deliberate on the Hand's work — multi-round review structure with two phases. Phase "plan" runs after the plan is published (four profiled member reviews of plan.md, Counselor oversight, two Hand syntheses, two `update-github-issue` pushes). Phase "diff" runs after the Hand executes (four profiled member reviews of the actual git diff, Counselor oversight, two Hand syntheses, one `update-github-issue` push). The Hand calls this skill twice in a meeting flow — once per phase, with execution sandwiched between. Distinct from ad-hoc council consults (which need no meeting).
---

# Convene a Meeting

The Hand convenes a meeting when a ticket is too complex to ship on a single judgment. A meeting has two phases:

- **Phase `plan`** — Council deliberates on the published plan before the Hand executes. Catches missing files, scope creep, security concerns, scope vs. budget mismatches, history nobody remembered.
- **Phase `diff`** — Council deliberates on the actual code change after the Hand executes. Catches regressions, edge cases the plan glossed over, conventions the implementation drifted from, security issues only visible in the diff.

The Hand calls this skill **twice** for a meeting-flow run — once with `phase: "plan"` after Step 2b (publish plan), once with `phase: "diff"` after Step 5 (execute). It's all-or-nothing: if the Hand convened a meeting, both phases run.

A meeting is distinct from an **ad-hoc consult**: the Hand can dispatch any single council member at any step (`Skill("_capture-planetscale", ...)`, `Agent(master-of-laws, "action: run-verification ...")`) without invoking a meeting. Meetings are the formal multi-round structure; ad-hoc consults are routine.

## Inputs

```
{
  phase:           "plan" | "diff",
  workdir:         "<abs — code worktree>",
  assetsWorkdir:   "<abs — assets worktree at <sessionPath>/assets-worktree>",
  assetsRef:       "refs/thk/<TICKET-CODE>",
  contextDir:      "<abs — session context>",
  planPath:        "<abs — context/plan.md>",
  ticketCode:      "<ENG-10105>",
  issueUrl:        "<from publish-plan-to-github>",
  runtimeProfile:  <resolved profile object>,
  baseBranch?:     "<base branch — diff phase only, default `main`>"
}
```

## Output

```
{
  phase:           "plan" | "diff",
  finalAssetsSha:  "<40-char SHA of the last bundle commit in this phase>",
  rounds: {
    one: { grandMaester, masterOfLaws, lordCommander, masterOfCoin },  // one-liner per member
    two: <counselor's verdict line>
  },
  planRevised?:    boolean,    // plan phase only
  diffRevised?:    boolean,    // diff phase only — true if Hand fixed any flagged issues
  notes?:          string
}
```

## Where artifacts live

Both phases write to `<contextDir>/plan-reviews/`. The folder structure carries the phase suffix so both phases can coexist without overwriting:

- `plan-reviews/round-1-plan/` — plan-phase member reviews
- `plan-reviews/round-2-plan/` — plan-phase Counselor oversight
- `plan-reviews/round-1-diff/` — diff-phase member reviews
- `plan-reviews/round-2-diff/` — diff-phase Counselor oversight
- `plan-reviews/hand-decision.md` — single audit trail across both phases. Plan phase appends Sections 1–2 (member verdicts, Counselor verdicts on the plan); diff phase appends Sections 3–4 (member verdicts on the diff, Counselor verdicts on the diff).

## Profile-aware dispatch

Every hard-coded `Agent(<member>, ...)` example below is shorthand for "dispatch the role through `runtimeProfile.profile.roles.<role>`":

- If `runner` is `claude-code`, use the configured `agent` and pass the configured `model` as the Agent model override.
- If `runner` is `codex-cli` / `gemini-cli` / a role with a custom `command`/`args`, run `${CLAUDE_PLUGIN_ROOT}/scripts/run-profiled-role.mjs` with `--profile`, `--role`, `--action`, `--workdir`, `--context-dir`.
- If `runner` is `manual`, write the generated prompt to `<contextDir>/profiled-prompts/<role>-<action>.md` and return a degraded envelope.
- If `runtimeProfile.profile.parallel` is `false`, run roles sequentially even where this spec says "parallel".

---

## Phase `plan` — review the published plan

### Step 1 — Dispatch the four profiled member reviews

If `runtimeProfile.profile.parallel` is `true` and the four roles use `claude-code`, dispatch concurrently in one message; otherwise sequentially. Each writes to `<contextDir>/plan-reviews/round-1-plan/<member-slug>.md`:

```
Agent(grand-maester,  prompt="action: review-plan-history.  workdir: <w>. contextDir: <c>. planPath: <c>/plan.md. ticketCode: <code>.")
Agent(master-of-laws, prompt="action: review-plan-rules.    workdir: <w>. contextDir: <c>. planPath: <c>/plan.md. ticketCode: <code>.")
Agent(lord-commander, prompt="action: review-plan-security. workdir: <w>. contextDir: <c>. planPath: <c>/plan.md. ticketCode: <code>.")
Agent(master-of-coin, prompt="action: review-plan-cost.     workdir: <w>. contextDir: <c>. planPath: <c>/plan.md. ticketCode: <code>.")
```

Lenses:

| Member | Lens |
|--------|------|
| **Grand Maester** | History, engineering wiki, missing files. Database consult on his own judgment if the plan is data-state-dependent. |
| **Master of Laws** | Business rules, TS strict-mode, codebase conventions. |
| **Lord Commander** | Security only — six lenses (injection, authz, secret/PII, race, supply-chain, DoS). |
| **Master of Coin** | Cost — is there a smaller patch? Quick-fix + tech-debt carveout proposal. |

### Step 2 — Synthesize Round 1 plan verdicts; revise plan; push update

Read the four review files. For each issue: **accept** (revise plan), **reject** (state why), or **defer** (carveout). Append Section 1 to `<contextDir>/plan-reviews/hand-decision.md`. If anything was accepted, revise `plan.md`. Then dispatch `master-of-ships` → `update-github-issue`.

### Step 3 — Counselor oversight pass on the plan

Dispatch the profile's `counselor` role with full visibility into the (revised) plan + four reviews + Hand's decisions. Save the response to `<contextDir>/plan-reviews/round-2-plan/<artifact>`.

### Step 4 — Synthesize Counselor's plan verdict; push update

Append Section 2 to `hand-decision.md`. Dispatch `master-of-ships` → `update-github-issue` again — even if no concerns, this re-bundles the now-complete Counselor artifact. Capture the returned SHA as `finalAssetsSha`. **Plan phase ends.**

---

## Phase `diff` — review the executed change

### Step 1 — Dispatch the four profiled member reviews on the diff

Same lenses, different target — the actual git diff vs. `<baseBranch>` (default `main`). Each writes to `<contextDir>/plan-reviews/round-1-diff/<member-slug>.md`:

```
Agent(grand-maester,  prompt="action: review-correctness.   workdir: <w>. contextDir: <c>. cycle: 1.")
Agent(master-of-laws, prompt="action: review-against-rules. workdir: <w>. contextDir: <c>. cycle: 1.")
Agent(lord-commander, prompt="action: red-team-review.      workdir: <w>. contextDir: <c>. cycle: 1.")
Agent(master-of-coin, prompt="action: scope-check.          workdir: <w>. originalEstimate: <from earlier estimate-effort if present, else null>.")
```

Lenses on the diff:

| Member | Lens |
|--------|------|
| **Grand Maester** | Correctness + edge cases (`review-correctness`). Did the diff actually solve the root cause? Are there regressions? |
| **Master of Laws** | Rules check (`review-against-rules` — static + Notion business rules). Plus runs `run-verification` if not already green. |
| **Lord Commander** | Adversarial security (`red-team-review`) — same six lenses, now on real code. |
| **Master of Coin** | Scope drift (`scope-check`) — does the diff stay within the plan's scope or did it sprawl? |

### Step 2 — Synthesize Round 1 diff verdicts; Hand fixes; push update

Read the four review files. For each issue: **accept** (Hand fixes the code), **reject** (state why), **defer** (carveout — file a tech-debt ticket via `master-of-coin` → `draft-techdebt-ticket` + `master-of-ships` → `create-linear-followup-ticket`).

Append Section 3 to `<contextDir>/plan-reviews/hand-decision.md`. If anything was accepted: edit the code (Hand alone, same single-agent approach as `_execute-plan`), then re-dispatch `master-of-laws` → `run-verification` to confirm green. Cap fixes at `maxIterations` (default 3 — same as `_execute-plan`'s cap).

If verification can't go green within the cap → return `notes: "post-review fixes failed verification"` and let the Hand decide whether to terminate at `pre-pr-review-failed` or proceed with a degraded PR. Do **not** push to GitHub during fixes; the diff being committed is the Hand's call after verification holds.

Once verification is green (or no fixes were needed), dispatch `master-of-ships` → `update-github-issue` so the diff-phase reviewer artifacts land in the issue's edit history.

### Step 3 — Counselor oversight pass on the diff

Dispatch the profile's `counselor` role with full visibility into the (possibly fixed) diff + four diff reviews + Hand's Round 3 decisions. Save to `<contextDir>/plan-reviews/round-2-diff/<artifact>`.

### Step 4 — Synthesize Counselor's diff verdict; push final update

Append Section 4 to `hand-decision.md`. Dispatch `master-of-ships` → `update-github-issue` one more time — re-bundles the complete diff-phase deliberation. Capture the returned SHA as `finalAssetsSha`. **Diff phase ends.**

---

## Rules

- Every reviewer's concern gets a verdict (accept / reject / defer) with reasoning in `hand-decision.md`. The Hand never silently ignores dissent.
- External advisors are advisory, not council members — they inform but do not vote.
- `update-github-issue` calls bound the meeting's GitHub edit-history footprint. Plan phase: 2 calls. Diff phase: 1–2 calls (after fixes are green, then after Counselor synthesis). Clean revisions, not per-review noise.
- A meeting is all-or-nothing per ticket. If `phase: "diff"` is invoked, `phase: "plan"` must already have completed — otherwise return `{ error: "diff phase requires plan phase to have run first" }`.
- If a reviewer crashes mid-round, log the gap in `hand-decision.md` and continue. Partial review is better than no review.
- Code edits during diff-phase fixes are the Hand's job, single-agent — same model as `_execute-plan`. Don't fan out to sub-agents.
- Never mark the PR ready-for-review yourself. Even a green meeting and a green Counselor pass don't take the PR out of Draft — that's the human reviewer's call.
- Log every dispatch via `${CLAUDE_PLUGIN_ROOT}/scripts/log.sh` with actor `hand`, events `dispatch` / `decision` / `error`, and the phase + round in the message ("plan-r1", "diff-r1", "diff-counselor", etc.).
