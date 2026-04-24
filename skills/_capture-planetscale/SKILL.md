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
6. **Banned tables.** The query must not reference the `employee` or `employees` tables (case-insensitive, including schema-qualified forms like `hr.employees`, aliased forms like `employees e`, and any subquery or CTE reading from them). These tables hold sensitive HR data and are off-limits regardless of purpose — no exceptions, no "read only one column", no workarounds. If matched, reject with reason `banned table: employee(s)`.

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
