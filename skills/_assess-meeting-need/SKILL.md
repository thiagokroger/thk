---
name: _assess-meeting-need
description: The Grand Maester reads the plan, scans the codebase + git history for similar prior efforts and surface signals (auth / schema / payment / migrations / multi-file scope), and returns an evidence-grounded verdict on whether a formal Small Council meeting is warranted. Replaces the Hand's old heuristic self-judgement at Step 3 — the Grand Maester is now the meeting-need oracle. Read-only, fast, cites concrete file paths and past PRs in the reasoning.
---

# Assess Meeting Need

The Hand asks you, the Grand Maester, one question: **does this plan need a formal Council meeting, or can it ship through the simple path?**

A meeting is expensive — four parallel reviewers + Counselor + multiple Hand syntheses + two GitHub-issue pushes. It's worth that price when the change has historical or structural weight; it's overhead when the change is routine. You already read code and git history — apply that to the meeting decision.

You do **not** invent rules from scratch. You ground the verdict in evidence: which files the plan touches, how often those files change, whether similar past efforts went smoothly or required rework, and whether the affected surface (auth, schema, payment, PII, dependencies) carries inherent risk regardless of size.

## Inputs

```
{
  workdir:    "<abs — code worktree>",
  contextDir: "<abs — session context>",
  planPath:   "<abs — context/plan.md>",
  ticketCode: "<ENG-10105>"
}
```

## Output

```
{
  recommend_meeting: boolean,
  weight_score:      <int 1-10>,        // 1 = trivial, 10 = high-stakes
  evidence: {
    files_in_plan:          ["<rel-path>", ...],
    weight_signals:         ["auth-surface", "schema-change", ...],
    similar_past_prs:       [{ url, title, sha, took_iterations: <int>, had_revert: bool }, ...],
    history_density:        { "src/api/auth.ts": <commits-last-90d>, ... },
    revert_or_hotfix_count: <int>       // commits matching `^revert:|^hotfix:|fix:.*regression` near affected files
  },
  reasoning: string                      // narrative — cite specific files and past PRs
}
```

## Procedure

### 1. Read the plan

Read `<planPath>`. Extract:

- **Files touched** — union of `Files to modify`, `Files to add`, `Files to delete` tables. If the plan uses a different shape, scan the prose for explicit file references.
- **Approach prose** — note whether it mentions schema, migrations, auth, sessions, payments, billing, PII, encryption, third-party services, or new dependencies.
- **Tests section** — empty tests + non-trivial code change is itself a weight signal.

### 2. Detect weight signals on the affected files

For each file in the plan:

| Signal | Detection |
|---|---|
| `auth-surface` | Path matches `auth/`, `session/`, `permission`, `oauth`, `passport`, `jwt`, `cookie`, `csrf`, `acl`, `rbac` |
| `payment-surface` | Path matches `billing`, `payment`, `stripe`, `checkout`, `subscription`, `invoice`, `dunning` |
| `pii-surface` | Path matches `users`, `profile`, `address`, `phone`, `ssn`, or imports a known PII column accessor (consult `<workdir>/.claude/.thk/policies.json:lord_commander.sensitive_paths` if defined) |
| `schema-change` | Path matches `migrations/`, `schema.sql`, `schema.prisma`, `models/`, `*.gen.ts` for ORM-generated types, or extension `.sql` |
| `dependency-change` | Path matches `package.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lockb`, `Cargo.toml`, `go.mod`, `requirements.txt`, `Gemfile`, `composer.json` |
| `multi-file-scope` | More than 5 files in the plan |
| `wide-touch` | The plan spans 3+ top-level directories (`src/api`, `src/ui`, `src/jobs`) |
| `infra-config` | Path matches `Dockerfile`, `*.yml` under `.github/workflows/`, `terraform/`, `k8s/`, `nginx`, `infra/` |
| `unverified-tests` | Plan's Tests section is empty AND `weight_signals` already non-empty |

The team can extend the patterns by writing them to `<workdir>/.claude/.thk/policies.json:review.weight_signals` (override / extend the defaults).

### 3. Read git history on the affected files

For each file in the plan, run:

```bash
cd <workdir>
git log --since="3 months ago" --oneline -- <file>
```

Compute `history_density` = number of commits per file. A file with 20+ commits in 90 days is volatile; a file untouched for 90 days is settled.

Then look for past trouble:

```bash
cd <workdir>
git log --since="6 months ago" --oneline --grep='^\(revert\|hotfix\|fix:.*regression\)' -- <file>
```

Count matches across all plan files → `revert_or_hotfix_count`. Past reverts and hotfixes near the affected code are strong meeting signals — that surface has produced incidents recently.

### 4. Find similar past efforts

Two passes:

**4a. Same-files past PRs.** For each plan file, search recent merged PRs that touched it:

```bash
gh pr list --state merged --search "<file-rel-path>" --limit 5 --json number,title,url,mergedAt,headRefOid
```

Or via git log if `gh` is unavailable:

```bash
git log --since="3 months ago" --merges --grep="^Merge pull request" -- <file>
```

For each match, note: title, URL, merge SHA, and whether it had post-merge fixups (search `git log <merge-sha>..HEAD --grep='<original-pr-title>'` for follow-ups).

**4b. Same-keywords past tickets.** Extract 2–3 distinctive nouns from the plan's title (skip stop-words like "fix", "update", "add"). Search merged PRs and prior thk-published GH issues:

```bash
gh pr list --state merged --search "<keyword> in:title" --limit 5 --json number,title,url
gh issue list --search "<keyword> in:title label:thk-managed" --limit 5 --json number,title,url
```

For matches, the historical iteration count (commits between first push and merge SHA, or thk-issue marker `thk-meeting=yes/no`) tells you whether similar past efforts were one-shots or required council deliberation.

If `gh` is not authenticated → silently skip the GH searches; rely on git log alone. Log a one-line stderr notice but do not error.

### 5. Compute weight_score

Start at 0. Add:

| Signal class | Each occurrence adds |
|---|---|
| auth-surface, payment-surface, pii-surface | +3 |
| schema-change, dependency-change | +2 |
| multi-file-scope, wide-touch | +1 |
| infra-config | +2 |
| unverified-tests | +2 |
| revert_or_hotfix_count > 0 | +`min(revert_or_hotfix_count, 3)` |
| any similar past PR had `took_iterations >= 3` or `had_revert: true` | +2 |
| `history_density` max value > 15 | +1 |

Clamp to 1–10. Project policy can override the addition values via `policies.json:review.weight_weights` (rare; the defaults are tuned for typical web/backend repos).

### 6. Decide

| weight_score | Verdict | When to override |
|---|---|---|
| 1–3 | `recommend_meeting: false` | If any single hard signal is present (auth-surface, schema-change, payment-surface) → flip to `true` regardless of total score. Hard signals are non-discretionary. |
| 4–6 | `recommend_meeting: true` if any hard signal OR `revert_or_hotfix_count >= 2`; else `false` | The borderline range — let evidence break the tie. |
| 7–10 | `recommend_meeting: true` | Don't second-guess. |

### 7. Compose reasoning

Write a concise narrative (3–6 sentences). It must:

- Lead with the verdict and the weight_score.
- Cite specific files (file:line not required — file path is fine).
- Cite the strongest evidence: a past PR URL with a problematic outcome, a high history_density file, a hard signal.
- End with what the meeting would catch (or, on a no-meeting verdict, what makes the change low-risk).

Example (recommend yes):

> **Recommend meeting (weight=7).** The plan touches `src/billing/checkout.ts` and adds a Stripe webhook handler at `src/api/webhooks/stripe.ts` — both payment-surface. `git log --since=3mo` shows `src/billing/checkout.ts` had 23 commits in 90 days and one `revert: bad subscription proration` from PR #4421. Similar past effort at PR #4498 (Stripe webhook signature verification) took 4 review rounds before merging. A meeting would catch the Lord Commander's signature-replay angle and the Master of Coin's "carve out idempotency" check; the no-meeting path is too narrow for this surface.

Example (recommend no):

> **No meeting (weight=2).** The plan modifies `src/ui/components/Avatar.tsx` to add a fallback initial when the image URL is null. One file, no signal classes triggered. `git log` shows the file is settled (3 commits in 90 days, no reverts, no hotfixes). Similar past effort at PR #4612 (Avatar empty-state) merged in one review round. Routine — the diff Counselor pass at Step 6a is sufficient oversight.

### 8. Return

Return the envelope above. Do not write any artifact files — the Hand records the verdict in `progress.md` and `hand-decision.md`. This skill is pure read + reason.

## Rules

- **Read-only.** No edits, no commits, no writes to disk. You only consult evidence.
- **Time-budget aware.** Aim for under 30 seconds of work — quick git log, quick gh pr list, quick file path matching. Don't sink into deep code reading; that's what the meeting is for.
- **Cite or don't claim.** Every signal in the verdict must be backed by a file path or a PR URL in the evidence. If you say "this is risky" without a citation, the Hand will discount the verdict.
- **Hard signals are non-negotiable.** Auth, schema, payment surfaces flip to `recommend_meeting: true` regardless of weight_score. The Hand may still override at the policy level (`meeting_decision: "never"`), but the Grand Maester's recommendation is unambiguous.
- **`gh` failure is not your failure.** If `gh` isn't authenticated or the API is rate-limited, fall back to `git log` and continue. Note the gap in the reasoning so the Hand knows what evidence was unavailable.
- **No personal opinion.** Don't say "this seems risky" — say "this touches `src/auth/session.ts` which had a `revert:` 8 days ago at PR #N." Evidence first, prose second.
- **Defer to policy override.** If `policies.json:review.meeting_decision` is `always` or `never`, the Hand skips this skill entirely. Your verdict is consulted only when the policy says `auto` (the default).
