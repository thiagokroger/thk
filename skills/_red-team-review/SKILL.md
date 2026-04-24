---
name: _red-team-review
description: Adversarial security review of a diff. Reads `git diff` with attacker intent across six lenses — injection, authz bypass, race conditions, PII/secret exposure, supply-chain, DoS — and greps adjacent code for pattern precedent. Specific findings with file:line citations only. No performative paranoia.
---

# Red-Team Review

## Inputs
```
{
  contextDir: "<abs>",
  workdir: "<abs>",
  cycle?: number
}
```

## Procedure

1. Read `<contextDir>/review-brief.md` and `<contextDir>/root-cause-analysis.md` for context.
2. `cd <workdir> && git diff`.
3. For every new/modified line, interrogate through six lenses:

**Injection** — SQL / shell / prompt / XSS / SSRF / path traversal.
**Authorization** — co-located checks? Bypass via different entry point? Does this relax an existing check?
**Race / TOCTOU** — state change between check & use? Concurrent writes without locking?
**Exposure** — tokens, secrets, PII in logs / error messages / responses / cache keys?
**Supply chain** — new packages, version bumps, unpinned ranges?
**DoS** — unbounded loops, allocations, external calls, catastrophic regex backtracking?

4. Grep adjacent patterns in the codebase to determine whether the weakness is new vs. inherited.

5. Do NOT flag items under "Intentional Design Decisions" in `review-brief.md`. Note them in `notes` so the Hand can confirm they still hold under adversarial light.

## Severity

- **blocker** — exploitable by an unauthenticated or low-privileged actor in production.
- **major** — exploitable under realistic abuse scenarios (insider, compromised session).
- **minor** — defense-in-depth gap, hardening opportunity.

## Output
```
{
  approved: boolean,
  issues: [{ severity, category: "injection"|"authz"|"race"|"exposure"|"supply-chain"|"dos", file, line?, description, suggestion? }],
  notes: string
}
```

## Rules
- Specific > general. "Authz bypass" is not a finding; "`DELETE /runs/:id` at server.ts:87 has no ownership check" is.
- No performative paranoia. If an attack requires compromising the developer's laptop, skip or mark minor.
- Silence is not approval — if no findings, say so explicitly.
