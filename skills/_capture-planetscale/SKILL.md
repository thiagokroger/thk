---
name: _capture-planetscale
description: Run one targeted, READ-ONLY SELECT query against the production database via the PlanetScale MCP to capture data context relevant to the ticket — e.g. "look up user by email", "inspect order state", "check auth records". Writes the result to `context/planetscale/` as a markdown table. Rejects anything that isn't a plain single-statement SELECT. Redacts credential / secret / PII-like columns automatically. Owned by the Grand Maester (not the Master of Whisperers) — invoked on his own judgment when a ticket or plan hinges on a specific record's state.
---

# Capture PlanetScale

Runs a scoped, read-only query to surface a specific slice of production data that's relevant to the ticket. Never modifies data. Never scans broadly.

**Caller contract.** This skill is owned by the Grand Maester and invoked as a sub-skill from within his `investigate-root-cause` and `review-plan-history` actions — never dispatched as a standalone action by the Hand. The decision of whether to run a DB consult is judgment-driven, not URL-driven: the Grand Maester decides based on the ticket + plan + captured context whether a specific row's state would confirm or refute something load-bearing. Skip it for pure render / layout / logic bugs with no specific record in play.

## Inputs
```
{
  queryName: "<short slug for the output file — e.g. 'user-lookup-email'>",
  query:     "<one SELECT statement>",
  purpose:   "<one-line reason this query is needed for this ticket>",
  contextDir: "<abs>"
}
```

## Safety gate — run BEFORE executing

1. **Single statement.** Split the query on `;`. Trim whitespace. Any non-empty segment beyond the first → reject.
2. **SELECT only.** After stripping leading comments and whitespace, the query must start with `SELECT` or `WITH ... SELECT` (a CTE that feeds a SELECT).
3. **Banned keywords** (case-insensitive, anywhere in the query):
   `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `REPLACE`, `TRUNCATE`, `CREATE`, `ALTER`, `DROP`, `RENAME`, `GRANT`, `REVOKE`, `CALL`, `EXECUTE`, `PREPARE`, `INTO OUTFILE`, `INTO DUMPFILE`, `LOAD_FILE`, `SLEEP(`.
4. **Row limit.** If the query lacks an explicit `LIMIT`, append `LIMIT 100`. Never run an unbounded scan as context.
5. **Purpose required.** If `purpose` is missing or generic ("just checking"), reject.
6. **Project-banned tables (read from the target repo, not hardcoded here).** thk ships **no** project-specific table ban list — those vary by codebase. Before executing the query, read `<workdir>/AGENTS.md` (resolving any `@<file>` imports like `@AGENTS.md`) and look for a thk-specific safety section that declares banned tables. Common section headings to look for (case-insensitive):

   - `## thk: planetscale` / `## thk policies` / `## thk safety`
   - Any line of the form `Banned tables:` / `Off-limits tables:` / `PII tables:` followed by a comma-separated list

   If a structured config file `<workdir>/.thk/policies.json` exists, also honor:

   ```json
   {
     "planetscale": {
       "banned_tables": ["<table-name>", "<schema>.<table>", ...]
     }
   }
   ```

   The effective ban list is the **union** of AGENTS.md declarations and the JSON config (when both exist).

   Apply each declared ban case-insensitively and across **all** reference forms a SQL parser would recognize: bare (`<table>`), schema-qualified (`<schema>.<table>`), aliased (`<table> a` or `<table> AS a`), within subqueries, and within CTEs. If a match occurs anywhere, reject with reason `banned table: <table-name> (per <source>)` where `<source>` is `AGENTS.md` or `.thk/policies.json` depending on which declared it.

   If neither source declares any bans, this gate is a no-op — only the universal safety checks above apply.

   **Auto-mirror AGENTS.md → `policies.json` (first-run bootstrap).** When AGENTS.md declares bans in prose but `<workdir>/.thk/policies.json` doesn't yet have a `planetscale.banned_tables` entry, write a structured mirror of the prose declaration into `policies.json` so:

   - Future runs are deterministic (parsing AGENTS.md prose every time is fragile).
   - The team gets a machine-readable copy they can commit and version.
   - A reviewer skimming `policies.json` sees the safety rules without having to scan AGENTS.md.

   Behavior, identical to `_run-verification`'s auto-drop:

   - If `policies.json` doesn't exist → create with a `_meta` block + the `planetscale.banned_tables` block.
   - If it exists but lacks `planetscale.banned_tables` → merge in just that key.
   - If `planetscale.banned_tables` already exists → leave it alone (the human-edited value wins).
   - Log a one-line stderr notice when a write happens: `_capture-planetscale: mirrored <N> banned tables from AGENTS.md → <workdir>/.thk/policies.json. Review and commit.`

   The merged file uses the same shape as `_run-verification`'s auto-drop — both skills coexist by writing different top-level keys (`verification.*` vs `planetscale.*`) into the same JSON.

If any check fails → return `{ error: "query rejected: <reason>" }`. Do not execute.

## Procedure

1. Run the safety gate.
2. Execute the query via `mcp__planetscale__planetscale_execute_read_query`. If you need to verify a table / column name first, consult `mcp__planetscale__planetscale_get_branch_schema`. Never call `planetscale_execute_write_query` — it is out of scope for this skill regardless of what the query looks like.
3. Apply **column redaction** to the returned rows. Replace values in any column whose name matches the following patterns (case-insensitive) with the literal `<REDACTED>`:
   - `password`, `password_hash`, `passwd`, `pwd`
   - `salt`, `pepper`
   - `token`, `refresh_token`, `access_token`, `session_token`, `id_token`, `csrf_token`
   - `api_key`, `api_secret`, `secret`, `private_key`
   - `credit_card`, `card_number`, `cvv`, `ssn`
   - Anything ending in `_hash` or `_digest`
4. Write to `<contextDir>/planetscale/<queryName>.md`:

```markdown
# PlanetScale Query — <queryName>

**Purpose:** <purpose>
**Executed at:** <ISO 8601>
**Rows returned:** <count>
**Redacted columns:** <list, or "none">

## Query
\`\`\`sql
<query — the exact statement that ran, including any LIMIT auto-appended>
\`\`\`

## Results

| col1 | col2 | col3 |
|------|------|------|
| ...  | ...  | ...  |
```

If zero rows were returned, say so explicitly in the "Results" section (it's often the finding — e.g., "user not found" *is* the context).

## Output
```
{
  file: "planetscale/<queryName>.md",
  rowCount: number,
  redactedColumns: string[]
}
```

## Rules

- Read-only, single statement, row-limited. No exceptions — not even "for debugging."
- Redaction errs on the side of hiding. If a column would clearly leak a secret and the pattern didn't catch it, redact anyway.
- Output must be human-readable markdown (table form). Don't dump raw JSON.
- If the PlanetScale MCP is unavailable, return `{ error: "PlanetScale MCP unreachable" }`. Do not fall back to any other source.
- Do not scan without a specific purpose. Fishing expeditions ("give me all users") are rejected at the safety gate via the row limit + purpose check.
