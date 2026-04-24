---
name: _codex-review
description: Run an OpenAI Codex CLI review against the session's uncommitted diff with a specific framing — plan / correctness / review / red-team / free. Uses `codex exec --full-auto --disable enable_request_compression` with configurable model and reasoning effort. 2-hour timeout with a slim-retry fallback. Parses Codex's prose output into the standard verdict envelope.
---

# Codex Review

## Inputs
```
{
  framing: "plan" | "correctness" | "review" | "red-team" | "free",
  workdir: "<abs>",
  contextDir: "<abs>",
  ticketCode: "<ENG-123>",
  extraPrompt?: string,
  cycle?: number,
  model?: string,
  reasoningEffort?: "low" | "medium" | "high" | "xhigh"
}
```

## Procedure

Always `cd <workdir>` first — never run Codex from the main checkout. It must see the worktree's uncommitted diff.

```bash
cd <workdir>
codex exec --full-auto \
  --disable enable_request_compression \
  -c model="<model if provided>" \
  -c model_reasoning_effort="<reasoningEffort or xhigh>" \
  "<framing-specific prompt>"
```

Omit the `-c model="..."` argument when `model` is absent.

**Flags that must never change:** `--full-auto`, `--disable enable_request_compression`. Default `reasoningEffort` is `xhigh` when the profile does not supply one.

**Timeout:** 7200s (2h). If it hangs past 2h, retry once with a slimmer prompt (only `review-brief.md` + `git diff` — skip screenshots, skip other `context/` sub-files). If that also fails, return `{ approved: false, notes: "Codex unavailable after 2h + slim retry" }`.

**Never truncate the prompt.**

### Framings

**`"plan"`** — review an implementation plan before code is written.
```
You are reviewing an IMPLEMENTATION PLAN for ticket <TICKET-CODE>.

Read all files in <contextDir>/ for context, then review
the "Fix Approach" section of review-brief.md.

Focus:
1. Are there files or side effects the plan misses?
2. Could the approach break existing functionality?
3. Is there a simpler way to achieve the same result?
4. What tests should be added or updated?

Be concise and actionable.
```

**`"review"` / `"correctness"`** — review uncommitted changes.
```
You are reviewing UNCOMMITTED CHANGES for ticket <TICKET-CODE>.

BEFORE looking at the diff, read all files in <contextDir>/ to understand:
- linear/ — primary ticket + any linked issues, each with full comment threads
- jam/ — Jam evidence (details, transcripts, screenshots, console + network logs) — may be absent
- figma/ — design evidence (context, metadata, variables, screenshots, HTML) — may be absent
- root-cause-analysis.md — Grand Maester's investigation
- review-brief.md — the Hand's fix approach and intentional decisions

THEN run `git diff` and review for:
1. Correctness — does the fix actually address the root cause?
2. Edge cases — what could break?
3. Regressions — could this change break existing functionality?
4. Code quality — naming, structure, consistency with codebase conventions.

DO NOT flag items listed as "Intentional Design Decisions" in review-brief.md as issues.
If you find real problems, explain clearly what's wrong and suggest a fix.
If everything looks good, say so explicitly.
```

**`"red-team"`** — same preamble, adversarial focus:
```
... THEN run `git diff` and review ADVERSARIALLY:
1. Injection (SQL / shell / prompt / XSS / SSRF / path traversal)
2. Authorization bypasses — can a lower-privilege actor reach this path?
3. Race conditions, TOCTOU, concurrent-write issues
4. PII / secret exposure — logging, error messages, response payloads
5. Dependency supply chain — new packages, version bumps, unpinned ranges
6. Denial of service — unbounded loops, allocations, external calls

Be specific: cite file:line for every finding.
```

**`"free"`** — pass `extraPrompt` verbatim, prepended with:
```
Read all files in <contextDir>/ first for context. Then:
```

## Parsing the response

Codex's output is prose. Interpret into the envelope:

- `approved: true` only if the response contains no unresolved blockers/majors and no "should fix" / "must fix" / "issue" / "bug" / "problem" language. Conservative — when in doubt, `false`.
- `issues[]` — one entry per concern, severities:
  - `blocker` — "must fix", "broken", "will fail", "regression"
  - `major` — "should fix", "edge case", "inconsistent"
  - `minor` — "nit", "style", "prefer", "consider"
- `notes` — 1–3 sentence summary of Codex's verdict.
- `cycle` — echo the input `cycle` (default 1).

## Output
```
{
  approved: boolean,
  issues: [{ severity, file?, line?, description, suggestion? }],
  notes: string,
  cycle: number
}
```

## Rules
- Never truncate the prompt.
- If `workdir` doesn't exist or `git -C <workdir> diff` is empty → `{ approved: false, notes: "Empty diff or invalid workdir" }` immediately.
- If `codex` binary not on PATH → `{ approved: false, notes: "codex CLI not installed" }`. Do not attempt installation.
