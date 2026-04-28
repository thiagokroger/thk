---
name: _capture-figma
description: Exhaustively capture a Figma node via the Figma MCP — design context (code snippets, annotations, Code Connect), structured metadata, design tokens, libraries, Code Connect map, every available screenshot, and any user-provided Figma-to-Code HTML — into the session's `context/figma/<node-id>/` folder. Always writes a `README.md` index that points to every captured file and explains when to read each one, so downstream agents can navigate selectively without reading the whole folder. Verbatim — no summarization. Handles design files, branches, Figma Make, and FigJam variants.
---

# Capture Figma

Pulls everything the Figma MCP can offer for one node URL. Writes a self-contained `<contextDir>/figma/<node-id>/` folder with an index (`README.md`) that lists every file plus a one-line "read when" hint, so a downstream agent (the Hand drafting the plan, a council member reviewing it, or a human picking up the GitHub issue) can jump to the right artifact without slurping the whole folder into its context window.

## Inputs

- `figmaUrl` — the Figma URL.
- `contextDir` — absolute path to the session's context folder.
- `figmaToCodeHtml?` — optional list of HTML exports the King pasted in-conversation: `[{ name: string, content: string }]`.

## What's captured (always — when the MCP returns content)

| Source | File(s) written | Notes |
|--------|----------------|-------|
| `mcp__figma__get_design_context` | `context.md` (prose) + `code/<n>.<ext>` (raw fenced-code blocks extracted) | Code is typically React+Tailwind shaped to the project's stack via Code Connect. Save the prose AND extract code blocks into separate files so an agent can `cat` the raw code without re-parsing markdown. |
| `mcp__figma__get_metadata` | `metadata.md` (markdown rendering with the JSON inlined as a fenced block) | Structured node tree: dimensions, fills, strokes, children. |
| `mcp__figma__get_variable_defs` | `variables.md` (omit if the MCP returned nothing) | Design tokens — colors, typography, spacing. |
| `mcp__figma__get_libraries` | `libraries.md` (omit if none) | What component libraries this file pulls from. Tells reviewers whether a component lives in a shared library vs locally. |
| `mcp__figma__get_code_connect_map` | `code-connect.md` (omit if none) | Mapping from Figma components → codebase component paths. The most direct "where does this design live in code" answer. |
| `mcp__figma__get_screenshot` | `screenshots/<n>.png` (downloaded via `curl`) | Always PNG, MCP-default size. **Every screenshot must be on disk** — never a URL reference in markdown. |
| Caller-provided | `html/<name>.html` (verbatim) | Higher-fidelity than `context.md`'s code when present — use first. |

Plus, **always**:

- `README.md` — the index (described below).

## Procedure

### 1. Parse the URL

Extract `fileKey` + `nodeId` per Figma URL rules:

- `figma.com/design/:fileKey/...?node-id=:nodeId` → convert `-` to `:` in nodeId.
- `figma.com/design/:fileKey/branch/:branchKey/...` → use `branchKey` as fileKey.
- `figma.com/make/:makeFileKey/...` → use `makeFileKey` as fileKey.
- `figma.com/board/:fileKey/...` → FigJam variant; use `mcp__figma__get_figjam` instead of the design-context flow (skip the design-shaped tools below).

### 2. Capture from the MCP

For design / Make files, call each tool in turn. Tolerate per-tool failures — if one returns empty / errors, skip its file but continue the rest. Don't abort the capture on a single tool's miss; the README's "Files in this folder" table will simply not list the missing file.

```
mcp__figma__get_design_context(fileKey, nodeId)
mcp__figma__get_metadata(fileKey, nodeId)
mcp__figma__get_variable_defs(fileKey, nodeId)
mcp__figma__get_libraries(fileKey)
mcp__figma__get_code_connect_map(fileKey)
mcp__figma__get_screenshot(fileKey, nodeId) → curl PNG(s) to screenshots/
```

For FigJam (`figma.com/board/...`):

```
mcp__figma__get_figjam(fileKey, nodeId)
mcp__figma__get_screenshot(fileKey, nodeId) → screenshots/
```

### 3. Extract code blocks from `get_design_context`

`get_design_context` returns prose mixed with code blocks (React+Tailwind, sometimes raw HTML/CSS). Save the prose verbatim to `context.md`, **and** scan it for fenced code blocks (```` ```tsx ````, ```` ```jsx ````, ```` ```html ````, ```` ```css ````, etc.) — write each block to `code/<n>.<ext>` where `<ext>` matches the fence language (default `.txt` if none).

Naming: number the blocks in the order they appear (`code/1.tsx`, `code/2.css`, `code/3.html`, …). Index them in the README so a reader knows what each corresponds to. If `get_design_context` returns no code blocks, skip the `code/` folder entirely.

### 4. Persist any provided HTML

If `figmaToCodeHtml` was passed, save each item verbatim to `<contextDir>/figma/<node-id>/html/<name>.html`. Don't merge with `code/` — caller-provided HTML may differ in fidelity from MCP-returned code, and the index documents both.

### 5. Download every screenshot

For each URL returned by `get_screenshot`:

```bash
curl -sL -fSo "<contextDir>/figma/<node-id>/screenshots/<n>.png" "<url>"
```

If `curl` fails for a single screenshot (network blip, expired URL), retry once; if still failing, log to stderr and continue — note the gap in the README ("screenshots/2.png missing — fetch failed: <reason>"). Don't fail the whole capture on a single screenshot miss.

### 6. Write `README.md` — the index (always)

This is the file every downstream reader hits first. It's the difference between "agent slurps the entire folder into context" and "agent reads 200 bytes of index, then opens exactly the file it needs."

Template (substitute every `<…>` with the captured value; omit rows for files that weren't written):

```markdown
# Figma capture — <node-name from metadata, or "(unnamed node)" if absent>

**Source URL:** <figmaUrl>
**File:** <file-name from metadata> (`<fileKey>`)
**Node:** `<node-id>` · <node type — FRAME / COMPONENT / INSTANCE / GROUP / etc.> · <dimensions if available, e.g. "1440 × 900">
**Page:** <page name from metadata, when discoverable>
**Captured at:** <ISO 8601 UTC>
**MCP tools succeeded:** <comma-separated list of tools that returned content — e.g. `get_design_context, get_metadata, get_screenshot`>
**MCP tools that returned empty:** <comma-separated list — e.g. `get_variable_defs, get_libraries`>

## How to use this folder

Don't read every file. Read this index, then open only the files relevant to your task.

## Files in this folder

| File | What it contains | Read when |
|------|------------------|-----------|
| `screenshots/<n>.png` | <count> PNG render(s) of the node | **First stop** for anything visual — what does this design actually look like? |
| `context.md` | Prose design context: annotations, layout notes, component descriptions, code-shape hints | You need the design's intent / structure described in words, not just code. |
| `code/<n>.<ext>` | <count> raw code block(s) extracted from `get_design_context` (typically React+Tailwind, sometimes HTML/CSS) | You want to copy or adapt code verbatim — these are deduped from `context.md` so you don't have to re-parse markdown. |
| `metadata.md` | Structured node tree — dimensions, fills, strokes, children, layout constraints | Pixel-precise dimensions, exact hex colors when tokens didn't catch them, layout-tree exploration. |
| `variables.md` | Design tokens defined in the file — colors, typography, spacing, effects | Mapping a hardcoded value back to a token, or finding the right token name to use. |
| `libraries.md` | Component libraries this file pulls from | The component might live in a shared library — check before defining a new one. |
| `code-connect.md` | Code Connect map — Figma component → codebase component path | The fastest "where does this live in code" answer, when the team has Code Connect set up. |
| `html/<name>.html` | Hand-pasted HTML/CSS the King provided in-conversation | Often higher-fidelity than `context.md`'s code — use **before** `code/<n>` if both exist. |

## Code blocks index

(Omit this section if no `code/` folder.)

| File | Language | Approx. line count | What it is |
|------|----------|-------------------|------------|
| `code/1.tsx` | TSX | <n> | <one-line description from the surrounding prose in `context.md`, e.g. "Top-level page component"> |
| `code/2.css` | CSS | <n> | <one-line description, e.g. "Custom styles for the modal"> |

## Captured tool output sizes

(One-liner per file — useful when an agent is deciding whether opening a file is worth the context-window cost.)

- `screenshots/`: <n> PNG(s), total <X> KB
- `context.md`: <n> lines
- `code/`: <n> file(s), <n> total lines
- `metadata.md`: <n> lines
- `variables.md`: <n> lines
- `libraries.md`: <n> lines
- `code-connect.md`: <n> lines
- `html/`: <n> file(s), total <X> KB

## Source URL

<figmaUrl>
```

Build the table dynamically — only include rows for files that were actually written. Always include the screenshots row when any PNG landed; always include `context.md` when `get_design_context` returned content. Skip rows entirely (don't render with "(empty)") for files that weren't created.

### 7. Final folder shape

```
<contextDir>/figma/<node-id>/
├── README.md                ← always written
├── context.md               ← from get_design_context (when non-empty)
├── code/                    ← extracted code blocks (when context had any)
│   ├── 1.tsx
│   ├── 2.css
│   └── …
├── metadata.md              ← from get_metadata
├── variables.md             ← from get_variable_defs (omit if empty)
├── libraries.md             ← from get_libraries (omit if empty)
├── code-connect.md          ← from get_code_connect_map (omit if empty)
├── screenshots/             ← from get_screenshot
│   ├── 0.png
│   └── …
└── html/                    ← from caller-provided figmaToCodeHtml (omit if none)
    └── <name>.html
```

## Output

```
{
  fileKey:         string,
  nodeId:          string,
  nodeName:        string | null,
  nodeType:        string | null,    // FRAME / COMPONENT / INSTANCE / GROUP / SECTION / …
  pageName:        string | null,
  screenshotCount: number,
  codeBlockCount:  number,
  filesWritten:    string[],         // every relative path written, including README.md
  toolsSucceeded:  string[],         // ["get_design_context", "get_metadata", ...]
  toolsEmpty:      string[],         // tools that returned no content (not errors — just empty)
  toolsFailed:     [{ tool: string, reason: string }]   // tools that errored
}
```

## Rules

- **Every screenshot must be on disk.** Never reference a Figma image URL in markdown — the URLs expire and break the GitHub issue's self-contained contract.
- **Never summarize.** `context.md` is verbatim from the MCP. `metadata.md` includes the raw JSON. The README is an *index*, not an analysis — don't editorialize design choices.
- **Tolerate per-tool failures.** A single MCP tool returning empty or erroring should not abort the capture. Note the gap in the README's "MCP tools that returned empty" / "tools failed" lines and proceed.
- **`get_libraries` and `get_code_connect_map` are file-scoped** (not node-scoped). When capturing multiple nodes from the same `fileKey` across multiple Whisperer dispatches, you'll get the same library/code-connect data each time. That's fine — write it to each node's folder. Storage is cheap; per-node self-containment matters more.
- **FigJam (`figma.com/board/`) uses a different API path** — handle with `mcp__figma__get_figjam`. The README template still applies; just adjust the "MCP tools succeeded" line to reflect FigJam-specific tools.
- **If the Figma MCP is fully unavailable**, return `{ error: "Figma MCP unreachable", figmaUrl }` — do not proceed with partial data and do not write a partial folder. Per-tool failures are different from MCP-down: the latter aborts; the former skips the affected file.
- **The README is mandatory.** Even on a thin capture (e.g., screenshot only because every other tool returned empty), write the README so the reader knows what was attempted.
