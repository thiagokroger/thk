---
name: _investigate-root-cause
description: Produce `root-cause-analysis.md` for a session. Reads the captured context (tickets from the source MCP, Jam recordings, Figma designs), traces the relevant code paths via Grep/Read, consults `git log`/`blame` for history, and optionally the Notion MCP for documented conventions and the PlanetScale MCP (via the `capture-planetscale` sub-skill) for read-only database evidence when the ticket hinges on a specific record's state. Cites evidence with file:line + commit sha + Notion URLs + `planetscale/*.md` paths.
---

# Investigate Root Cause

## Inputs
```
{
  ticketCode: "<ENG-123>",
  contextDir: "<abs>",
  workdir: "<abs>"
}
```

## Procedure

1. Read every file in `<contextDir>/linear/`, `<contextDir>/jam/`, `<contextDir>/figma/`.
2. Locate relevant code via `Grep` / `Glob`.
3. Trace the code path producing the observed behavior — follow imports, follow calls.
4. `git log --all --follow <file>` + `git blame` on suspect lines. Past fixes in the same area are strong evidence.
5. If the touched area is documented in Notion, query live via Notion MCP.
6. **Optional — consult the production database.** If (and only if) the ticket names a specific record by identifier (user email / ID, order ID, session ID, etc.) and the code path alone cannot tell you whether the bug is a data-state issue vs. a logic issue, invoke the `capture-planetscale` sub-skill via `Skill` with a narrow SELECT (targeted WHERE, minimal columns, explicit `LIMIT`, one-line `purpose`). The sub-skill enforces the read-only safety gate and writes to `<contextDir>/planetscale/<queryName>.md`. Skip this step for pure render / layout / logic bugs with no specific record in play. Never call the PlanetScale MCP directly — always go through the sub-skill. If the MCP is unreachable, skip silently.
7. Write `<contextDir>/root-cause-analysis.md`:

```markdown
# Root Cause Analysis — <TICKET-CODE>

## Observed behavior
<paragraph>

## Expected behavior
<paragraph>

## Where it lives
<file paths + line numbers>

## Why it's broken
<mechanism traced through the code — not speculation>

## Relevant history
<git log/blame findings — past commits, who touched it, why>

## Wiki references
<Notion page titles + URLs + quoted conventions>

## Data evidence
<Omit this section entirely if no DB consult was run.>
<`planetscale/<queryName>.md` paths + the finding: what the row state says about the bug.>

## Open questions
<unknowns worth flagging>
```

## Output
```
{
  artifact: "root-cause-analysis.md",
  summary: "<1 sentence>"
}
```

## Rules
- Cite evidence — file:line, commit sha, Notion URL, `planetscale/<queryName>.md` path. Never assert without a pointer.
- If the root cause cannot be traced, write the file anyway with "Unknown — see Open questions" and list specific unknowns.
- Database consultation (step 6) is **optional and driven by judgment** — skip whenever it isn't clearly needed. Never invoke the PlanetScale MCP directly; always go through the `capture-planetscale` sub-skill.
