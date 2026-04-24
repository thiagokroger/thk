---
name: _capture-linear
description: Exhaustively capture a Linear ticket's full context via the Linear MCP — metadata, every comment (paginated), and every linked/parent/sub/related issue with their comments — into the session's context/linear/ folder as one markdown file per ticket. Invoke with the primary ticket URL; the skill recursively captures related issues. Also detects Vercel preview URLs of the shape `<project>-pr-XXXX-preview.vercel.app` and returns the PR number for base-branch resolution downstream.
---

# Capture Linear

Downloads every scrap of a Linear ticket via the Linear MCP and writes it to `<contextDir>/linear/<TICKET-CODE>.md`. Verbatim — no summarization.

## Inputs

- `ticketUrl` — URL of the primary Linear ticket (or `ticketCode` directly).
- `contextDir` — absolute path to the session's context folder.

## What's captured

For the **primary ticket**:
- Metadata: code, title, description, labels, status, assignee, **assigner** (the person who assigned it — capture carefully), `gitBranchName`, parent issue, sub-issues, related issues, attachments (URLs + titles).
- **Every** comment (paginate until exhausted).

For **every linked / parent / sub / related issue**, repeat: metadata + every comment. Related issues often hold precedent for similar problems.

## Procedure

1. `mcp__linear__get_issue` on the primary ticket — fetch metadata.
2. `mcp__linear__list_comments` — paginate through every comment. Do not stop at the first page.
3. For each linked / parent / sub / related issue found in the primary's metadata, recurse: fetch issue + all its comments.
4. For each ticket fetched, write `<contextDir>/linear/<TICKET-CODE>.md`:

    ```markdown
    # <TICKET-CODE> — <title>

    **Assigner:** <name>
    **Assignee:** <name>
    **Status:** <status>
    **Labels:** <labels>
    **Branch:** <gitBranchName>
    **URL:** <issue URL>
    **Parent:** <parent ticket code, if any>
    **Sub-issues:** <list, if any>
    **Related:** <list of related ticket codes, if any>
    **Attachments:** <list of attachment URLs and titles, if any>

    ## Description

    <description verbatim — preserve markdown>

    ## Comments

    ### <author> — <timestamp>
    <body>

    ### <author> — <timestamp>
    <body>

    ...
    ```

5. Scan the primary ticket's description + every comment for Vercel preview URLs of the shape `<project>-pr-XXXX-preview.vercel.app` (adjust the pattern to match your team's preview URL convention). If found, extract the PR number.

## Output

```
{
  tickets: string[],               // every ticket code written
  commentCount: number,            // total comments across all tickets
  primaryTicket: {
    code: string,
    assigner: string,
    gitBranchName: string,
    prPreviewPrNumber?: number     // if a Vercel preview URL was found
  }
}
```

## Rules

- Capture every comment — paginate until exhausted. Do not stop at the first page.
- **Do not summarize.** Capture verbatim.
- Capture the assigner's name precisely — it's needed downstream for Linear tagging.
- Pass string content to MCPs with real newlines, not `\n` escape sequences.
- If the Linear MCP is unavailable, return `{ error: "Linear MCP unreachable" }` and let the caller escalate — do not proceed with partial data.
