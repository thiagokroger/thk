---
name: _capture-figma
description: Exhaustively capture a Figma design via the Figma MCP — design context (code snippets, annotations, Code Connect), metadata, variable definitions / design tokens, every available screenshot, and any user-provided Figma-to-Code HTML — into the session's context/figma/<node-id>/ folder. Invoke once per Figma URL. Handles design files, branches, Figma Make, and FigJam variants.
---

# Capture Figma

Downloads every available data point from a Figma node via the Figma MCP. Writes to `<contextDir>/figma/<node-id>/`. Verbatim — no summarization.

## Inputs

- `figmaUrl` — the Figma URL.
- `contextDir` — absolute path to the session's context folder.
- `figmaToCodeHtml?` — optional list of HTML exports the King provided in-conversation: `[{ name: string, content: string }]`.

## What's captured

- **Design context** (code snippets, annotations, Code Connect mappings).
- **Metadata** (structured).
- **Variable definitions** / design tokens.
- **Every available screenshot** (downloaded locally).
- Any Figma-to-Code **HTML** the King provided.

## Procedure

### 1. Parse the URL

Extract `fileKey` + `nodeId` per Figma URL rules:

- `figma.com/design/:fileKey/...?node-id=:nodeId` → convert `-` to `:` in nodeId.
- `figma.com/design/:fileKey/branch/:branchKey/...` → use `branchKey` as fileKey.
- `figma.com/make/:makeFileKey/...` → use `makeFileKey` as fileKey.
- `figma.com/board/:fileKey/...` → FigJam variant; use `mcp__figma__get_figjam` instead of the design-context flow.

### 2. Capture

Call each in turn:

- `mcp__figma__get_design_context` — code snippets, annotations, Code Connect mappings.
- `mcp__figma__get_metadata` — structured metadata.
- `mcp__figma__get_variable_defs` — design tokens (omit write if none returned).
- `mcp__figma__get_screenshot` → download PNG(s) via `curl -sL -o <contextDir>/figma/<node-id>/screenshots/<n>.png <url>`.

### 3. Persist any provided HTML

If `figmaToCodeHtml` was passed, save each item verbatim to `<contextDir>/figma/<node-id>/html/<name>.html`.

### 4. Write files

Under `<contextDir>/figma/<node-id>/`:

- `context.md` — design context + annotations + Code Connect.
- `metadata.md` — structured metadata.
- `variables.md` — design tokens (omit if none).
- `screenshots/*.png` — every screenshot downloaded.
- `html/*.html` — provided HTML, if any.

## Output

```
{
  fileKey: string,
  nodeId: string,
  screenshotCount: number,
  filesWritten: string[]
}
```

## Rules

- Every screenshot must be on disk — never a URL reference in markdown.
- **Do not summarize.** Capture verbatim.
- FigJam (`figma.com/board/`) uses a different API — handle with `mcp__figma__get_figjam`.
- If the Figma MCP is unavailable, return `{ error: "Figma MCP unreachable", figmaUrl }` — do not proceed with partial data.
