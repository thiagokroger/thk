---
name: _review-against-rules
description: Review an uncommitted diff against codified rules — TypeScript (via static reading), linter conventions, and business rules documented in repo-local agent docs (AGENTS.md / CLAUDE.md / .claude/rules) AND in Notion. Produces a list of violations with citations. Static only — see `run-verification` for actually running tsc/build.
---

# Review Against Rules

## Inputs
```
{
  contextDir: "<abs>",
  workdir: "<abs>",
  cycle?: number
}
```

## Procedure

1. Read `<contextDir>/review-brief.md` — note the "Files Changed" list.
2. `cd <workdir> && git diff` — read the changes.
3. **Read repo-local agent docs from `<workdir>` if present.** These are Tier-1 rules — same authority as Notion, often more specific to the codebase:
   - `<workdir>/AGENTS.md` — read in full. Treat any "hard invariants" / "must" / "do not" sections as binding.
   - `<workdir>/CLAUDE.md` — read in full. If it imports another file via `@<filename>` syntax, follow the import (e.g., `@AGENTS.md` means inline that file's content).
   - `<workdir>/.claude/rules/**/*.md` — any rule files the repo ships for Claude Code.
   - `<workdir>/.cursor/rules/**/*.md` — Cursor-specific rules; usually overlap with the above but worth a look.

   These files may already be in the system prompt via Claude Code's auto-load (when the session was launched from inside the target repo). **Read them anyway** — explicit beats implicit, and if `THK_TARGET_REPO` points at a different repo than Claude Code's cwd, auto-load doesn't fire and you'd miss the invariants entirely.
4. Consult Notion MCP for any **broader product / compliance** rule on the touched modules (authorization, data handling, naming, package boundaries, API contracts). Query live.
5. Flag every violation with a citation: `<workdir>/AGENTS.md` (or whichever file) for repo-local rules, Notion URL for Notion rules, file:line for code issues.

## Output
```
{
  approved: boolean,
  issues: [{ severity, rule: "tsc"|"lint"|"business", file, line?, description, suggestion?, citation? }],
  notes: string
}
```

## Rules
- Static only. Do not run the build — that's `run-verification`.
- Repo-local rules (AGENTS.md, CLAUDE.md, etc.) take precedence over Notion when they conflict — the file checked in next to the code wins.
- Business-rule violations must cite either the repo-local file path OR the exact Notion page URL and relevant passage.
- If Notion MCP is unavailable, proceed with code-side and repo-local checks and note the gap.
