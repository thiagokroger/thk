---
name: _publish-plan-to-github
description: Publish the Hand's plan to GitHub as a fully self-contained handoff issue. Commits the entire session `context/` folder under `.github/thk-assets/<session-id>/` inside the assets worktree, pushes the commit to `refs/thk/<TICKET-CODE>` (a custom ref outside branches and tags, invisible in the GitHub UI but pinned forever), and inlines plan.md + the primary ticket verbatim in the issue body. Asset URLs use the commit SHA so they survive forever regardless of branch lifecycle. A downstream agent or human developer with just `git clone` + the issue URL — no MCP access, no Linear credentials, no local session folder — must be able to pick up and finish the work. Uses `gh` CLI.
---

# Publish Plan to GitHub

Turns the Hand's `plan.md` into a standalone GitHub issue. The issue is the **handoff document** — thk may terminate here and hand off to another agent (Codex, Gemini, Grok) or a human developer. Anything they need must be reachable from the issue URL alone.

## Inputs

```
{
  workdir:       "<worktree absolute path — the code worktree, only used for `gh` repo context>",
  assetsWorkdir: "<absolute path to the assets worktree — e.g. <sessionPath>/assets-worktree>",
  assetsRef:     "refs/thk/<TICKET-CODE>",
  contextDir:    "<session context absolute path>",
  planPath:      "<absolute path to plan.md>",
  ticketCode:    "<ENG-10105>",
  runnerProfile: "<runtime profile name — e.g. claude_codex; stamped as a hidden marker so resume-from-different-machine can read it back>",
  labels?:       string[]
}
```

## Output

```
{
  issueUrl:        "https://github.com/<owner>/<repo>/issues/<n>",
  issueNumber:     <n>,
  attachmentCount: <int>,       // total files committed in this bundle commit
  assetsRef:       "refs/thk/<TICKET-CODE>",
  assetsSha:       "<40-char commit SHA — every issue-body URL uses this SHA>",
  notes?:          string       // e.g. privacy warning if the committed context looks sensitive
}
```

## The self-contained contract

This skill enforces one rule: **everything needed to execute the plan lives inside the GitHub issue or inside the repo.** No local-path references, no MCP dependencies, no Linear access required for the downstream worker. If any link in the issue body 404s, the contract is broken.

Downstream consumers who must work from this issue alone:
- A different AI agent (no MCP tools configured)
- A human developer on a different machine
- A future maintainer opening the ticket weeks later

## Procedure

### 1. Sanity checks

- `test -f <planPath>` — abort if missing.
- `test -d <contextDir>` — abort if context folder is missing.
- `test -d <assetsWorkdir>` — abort if the assets worktree is missing. `scaffold-session` creates it; if it's gone, the caller is out of order.
- `gh auth status` — abort if not authenticated.
- `cd <workdir> && git remote get-url origin` — confirm there's a GitHub remote. Parse `<owner>/<repo>`.

On any failure, return `{ error: "<reason>" }`.

### 2. Derive session-id

Extract from `<contextDir>`. The path is typically `<targetRepo>/.claude/.thk/sessions/<session-id>/context/`; take the second-to-last path segment as `session-id`. If the path doesn't match that shape, fall back to a timestamp-ticket slug.

### 3. Bundle the ENTIRE context folder into the assets worktree

All commit work happens in `<assetsWorkdir>`, **never** in `<workdir>`. The code worktree must stay clean so the eventual PR diff contains only code changes.

Copy every file under `<contextDir>/` — **excluding only `outcome.md`** (session-meta, not evidence) — into `.github/thk-assets/<session-id>/context/`, preserving sub-structure:

```
.github/thk-assets/<session-id>/context/
├── linear/<TICKET>.md                  # every captured ticket (primary + linked/parent/sub/related)
├── jam/<jam-id>/
│   ├── details.md
│   ├── transcript.md
│   ├── analysis.md
│   ├── console.json
│   ├── network.json
│   ├── events.json
│   └── screenshots/*.png
├── figma/<node-id>/
│   ├── README.md                       # index — always written by _capture-figma
│   ├── context.md                      # design-context prose
│   ├── code/*.{tsx,html,css,…}         # raw code blocks extracted from context.md
│   ├── metadata.md
│   ├── variables.md                    # omitted when the file declares none
│   ├── libraries.md                    # omitted when the file imports none
│   ├── code-connect.md                 # omitted when no Code Connect mappings exist
│   ├── screenshots/*.png
│   └── html/*.html                     # hand-pasted by the King, omitted when none
├── planetscale/<queryName>.md          # redacted SELECT results
├── plan.md                             # (also inlined at top of issue body)
├── root-cause-analysis.md              # if present
└── review-brief.md                     # if present
```

**Session metadata bundling.** Beyond the `context/` folder, three sibling files at the session root carry state that future runs need for resumption — `log.md`, `progress.md`, and `runtime-profile.json`. Copy each into the bundle as a peer of the `context/` folder so the GitHub issue carries them too:

```bash
session_root="$(dirname "$contextDir")"
[ -f "$session_root/log.md" ]              && cp "$session_root/log.md"              .github/thk-assets/<session-id>/session-log.md
[ -f "$session_root/progress.md" ]         && cp "$session_root/progress.md"         .github/thk-assets/<session-id>/session-progress.md
[ -f "$session_root/runtime-profile.json" ] && cp "$session_root/runtime-profile.json" .github/thk-assets/<session-id>/session-runtime-profile.json
```

Skip silently if any of them is missing (unusual — they're created early in the run — but not fatal). The `session-progress.md` + `session-runtime-profile.json` peers are what enables Step 1.5's rehydration path in `thk/SKILL.md` to reconstruct prior runs from the issue alone, with no inference required.

**Staging discipline** — never `git add .` / `-A`. Stage the `.github/thk-assets/<session-id>/` subtree by exact path only. The assets worktree has no other content, so the tree naturally stays scoped — but explicit staging is still the rule:

```bash
cd <assetsWorkdir>
mkdir -p .github/thk-assets/<session-id>/
cp -R <contextDir>/. .github/thk-assets/<session-id>/context/
rm -f .github/thk-assets/<session-id>/context/outcome.md
session_root="$(dirname "$contextDir")"
[ -f "$session_root/log.md" ]              && cp "$session_root/log.md"              .github/thk-assets/<session-id>/session-log.md
[ -f "$session_root/progress.md" ]         && cp "$session_root/progress.md"         .github/thk-assets/<session-id>/session-progress.md
[ -f "$session_root/runtime-profile.json" ] && cp "$session_root/runtime-profile.json" .github/thk-assets/<session-id>/session-runtime-profile.json
git add .github/thk-assets/<session-id>/
git commit -m "chore(thk): context bundle for <TICKET-CODE>"

# Push the new commit to the custom ref. `HEAD:<assetsRef>` names the source (local HEAD)
# and destination ref (a custom namespace outside refs/heads and refs/tags).
git push origin "HEAD:<assetsRef>"

# The SHA pins the URL forever — every issue-body link uses this value, not a ref name.
assetsSha="$(git rev-parse HEAD)"
```

Record `<assetsSha>` and `<file-count>` (output of `git show --stat HEAD | grep -c " | "`).

**URL format for issue body links — non-negotiable.** Every link to a bundled file in the issue body must use the **commit SHA**, not a ref name. GitHub's `/blob/<ref>/...` URL router only resolves refs under `refs/heads/*` and `refs/tags/*`; custom refs like `refs/thk/*` do **not** resolve by name, but commit SHAs always do.

| Use case | URL pattern | Why |
|----------|-------------|-----|
| Markdown link to a file (`[text](url)`) | `https://github.com/<owner>/<repo>/blob/<assetsSha>/.github/thk-assets/<session-id>/<path>` | Opens GitHub's rendered view (markdown → rendered, image → image viewer). Works in private repos for any authenticated viewer. |
| Inline image embed (`![alt](url)`) | `https://github.com/<owner>/<repo>/raw/<assetsSha>/.github/thk-assets/<session-id>/<path>` | Serves the raw bytes via GitHub UI host. Note: GitHub's camo proxy cannot fetch from private repos, so inline images may not render in private-repo issue bodies — for private repos prefer a markdown link to the blob URL instead of an inline `![]()` embed. |

Leading-slash paths like `/.github/thk-assets/...` are not URLs and will not render as links — never use them. Ref names with slashes work fine elsewhere but are irrelevant here; we always substitute the literal 40-char commit SHA.

**Privacy pass.** Scan the bundled markdown for obvious secrets — strings like `password=`, `api_key=`, `Bearer `, `ghp_`, `sk-`, `xoxb-`, or PII in PlanetScale results that the `capture-planetscale` redactor missed. If any found, do NOT block — add a `⚠️ Bundled context includes potential secret/PII markers; audit before the repo goes public` note to the output `notes`. Proceed.

**Repo visibility.** Run `gh repo view <owner>/<repo> --json visibility --jq .visibility` once and remember it. If `PRIVATE`, do not use `![]()` inline image embeds for screenshots in step 4c — render them as markdown links to the blob URL instead. If `PUBLIC`, inline image embeds via the `raw` URL are fine.

### 4. Compose the issue body

Three sections: **Plan** (verbatim), **Primary ticket** (inline, verbatim), **Attached evidence** (indexed, linked).

#### 4a. Plan section

Read `planPath` verbatim. First section of the body, no reformatting.

#### 4b. Primary ticket inline

Locate `<contextDir>/linear/<TICKET-CODE>.md`. Inline it fully inside a `<details>` block so the reader sees the ticket without clicking through:

```markdown
<details>
<summary>📋 Primary ticket — &lt;TICKET-CODE&gt;</summary>

&lt;full content of linear/&lt;TICKET-CODE&gt;.md, verbatim&gt;

</details>
```

#### 4c. Attached evidence index

For every file bundled in step 3, build a link using the URL format spec above. The token `<BLOB>` below is shorthand for `https://github.com/<owner>/<repo>/blob/<assetsSha>/.github/thk-assets/<session-id>` and `<RAW>` for `https://github.com/<owner>/<repo>/raw/<assetsSha>/.github/thk-assets/<session-id>` — substitute the literal full URLs in the actual body. **`<assetsSha>` is the 40-char commit SHA from step 3**, not a branch name and not a ref name.

Insert **hidden HTML comment markers** before the "Attached evidence" heading so future tooling (and `update-github-issue`, and a resume-from-different-machine `/thk` invocation) can read run state without parsing the rest of the body:

- `thk-assets-ref` — the custom ref the bundle lives on. Lets `update-github-issue` find the ref without scraping URLs.
- `thk-runner-profile` — which runner profile the run is using. Lets a resume on a different machine pick the same model assignments rather than re-resolving locally.
- `thk-meeting` — whether the Hand convened a meeting at Step 3. **Omit on first publish** (the decision hasn't been made yet); the next `update-github-issue` (after the Hand's Step 3 decision) sets it to `"yes"` or `"no"`.

```markdown
<!-- thk-assets-ref: refs/thk/<TICKET-CODE> -->
<!-- thk-runner-profile: <runtimeProfile.selected_profile> -->

## Attached evidence

**📜 [Session log](<BLOB>/session-log.md)** — chronological record of every agent interaction, every skill invocation, every decision, every error across this session. Start here if anything looks off.

This issue is self-contained. Every piece of captured context is pinned at a specific commit on a custom ref (`refs/thk/<TICKET-CODE>`) that lives outside `refs/heads/*` and `refs/tags/*` — invisible in the branch picker and tags tab, but preserved forever. A downstream agent or developer needs only `git clone` + this page to have the full session context. No MCP access, no Linear credentials, no Jam/Figma access required.

**Bundle location:** `.github/thk-assets/<session-id>/` pinned at commit `<assetsSha>` on `refs/thk/<TICKET-CODE>`.

To browse assets locally:
```bash
git fetch origin 'refs/thk/*:refs/thk/*'
git checkout refs/thk/<TICKET-CODE>
```

### Tickets

| Ticket | File |
|--------|------|
| &lt;TICKET-CODE&gt; (primary, inlined above) | [linear/&lt;TICKET-CODE&gt;.md](&lt;BLOB&gt;/context/linear/&lt;TICKET-CODE&gt;.md) |
| &lt;LINKED-TICKET-1&gt; | [linear/&lt;LINKED-1&gt;.md](&lt;BLOB&gt;/context/linear/&lt;LINKED-1&gt;.md) |
| ... | ... |

(Path is `linear/` for tickets sourced from the Linear MCP. Future sources will land in peer folders, e.g. `jira/`.)

### Jam recordings

For each `jam/<id>/`:

- **Details:** [details.md](&lt;BLOB&gt;/context/jam/&lt;id&gt;/details.md)
- **Transcript:** [transcript.md](&lt;BLOB&gt;/context/jam/&lt;id&gt;/transcript.md) — agent-readable narration of the recording
- **Analysis:** [analysis.md](&lt;BLOB&gt;/context/jam/&lt;id&gt;/analysis.md)
- **Console logs:** [console.md](&lt;BLOB&gt;/context/jam/&lt;id&gt;/console.md)
- **Network:** [network.md](&lt;BLOB&gt;/context/jam/&lt;id&gt;/network.md)
- **User events:** [user-events.md](&lt;BLOB&gt;/context/jam/&lt;id&gt;/user-events.md)
- **Screenshots:**
  - **Public repo** — inline with `![jam-0](<RAW>/context/jam/<id>/screenshots/0.png)` etc.
  - **Private repo** — link with `[jam-0](<BLOB>/context/jam/<id>/screenshots/0.png)` etc. (camo proxy cannot fetch raw bytes from private repos, so `![]()` would render as broken)

### Figma designs

For each `figma/<node-id>/` — start the entry with the index file so the reader knows what's in the folder before clicking through:

- **📋 Index (read this first):** [README.md](&lt;BLOB&gt;/context/figma/&lt;node-id&gt;/README.md)
- **Design context (prose):** [context.md](&lt;BLOB&gt;/context/figma/&lt;node-id&gt;/context.md)
- **Code blocks** (only when present): [code/](&lt;BLOB&gt;/context/figma/&lt;node-id&gt;/code/) — raw TSX / JSX / HTML / CSS extracted from `context.md` for direct copy/adapt
- **Metadata:** [metadata.md](&lt;BLOB&gt;/context/figma/&lt;node-id&gt;/metadata.md)
- **Variables:** [variables.md](&lt;BLOB&gt;/context/figma/&lt;node-id&gt;/variables.md) (only when present)
- **Libraries:** [libraries.md](&lt;BLOB&gt;/context/figma/&lt;node-id&gt;/libraries.md) (only when present)
- **Code Connect map:** [code-connect.md](&lt;BLOB&gt;/context/figma/&lt;node-id&gt;/code-connect.md) (only when present)
- **Screenshots:** same public/private rule as Jam — `![]()` for public, `[]()` link for private.
- **HTML exports:**
  <details><summary>figma/&lt;node&gt;/html/&lt;name&gt;.html</summary>

  [Open the committed file →](&lt;BLOB&gt;/context/figma/&lt;node-id&gt;/html/&lt;name&gt;.html)

  </details>

### Database query captures

For each `planetscale/*.md`:
- [&lt;queryName&gt;.md](&lt;BLOB&gt;/context/planetscale/&lt;queryName&gt;.md) — _&lt;first line of Purpose from the file&gt;_

### Analyst artifacts
- [root-cause-analysis.md](&lt;BLOB&gt;/context/root-cause-analysis.md) _(Grand Maester, if present)_
- [review-brief.md](&lt;BLOB&gt;/context/review-brief.md) _(Hand's fix approach, if present)_
- [plan.md](&lt;BLOB&gt;/context/plan.md) _(also inlined at top of this issue)_

---
_This issue was published by thk (the Hand of the King). Edits to the plan are pushed back to this same issue body via the `update-github-issue` skill so GitHub's revision history is the audit log._
```

Write the composed body to `/tmp/thk-issue-<session-id>.md`.

#### 4d. Body size check

If the composed body exceeds **65,000 characters** (GitHub issue body cap), the primary ticket's inline content is the usual culprit. Replace the inline `<details>` block with just the link (`[📋 Primary ticket](<url>)`) and retry. Never truncate.

### 5. Create the issue

```bash
cd <workdir>
gh issue create \
  --title "[thk] <TICKET-CODE>: <title-from-plan>" \
  --body-file /tmp/thk-issue-<session-id>.md \
  $(printf -- '--label %q ' "${labels[@]:-thk-plan}")
```

`<title-from-plan>` comes from the `# Plan — <TICKET-CODE>: <title>` first line of `plan.md`.

Capture the issue URL from `gh`'s stdout.

### 6. Verify the handoff

Spot-check that the self-contained contract holds. **The verification target is the URLs that actually appear in the issue body** — not the on-disk files. Files-on-disk being correct is necessary but not sufficient; the issue body's links must resolve.

1. Re-fetch the issue body via `gh issue view <issueNumber> --json body --jq .body`.
2. Extract every URL inside markdown link / image syntax (`](URL)`). Any path that does NOT start with `https://` is a structural failure → return `{ error: "issue body contains non-URL link: <path>" }` (e.g. a leading-slash repo path won't render as a link in GitHub's markdown).
3. Pick 2 random asset URLs from the extracted set (one markdown file, one image if present).
4. Verify the `<assetsSha>` is reachable on origin — `gh api "/repos/<owner>/<repo>/commits/<assetsSha>"` must return HTTP 200. If it 404s, the push in step 3 didn't land.
5. For private repos confirm the asset file exists at that SHA — `gh api "/repos/<owner>/<repo>/contents/<path>?ref=<assetsSha>"`. For public repos `curl -sI <url>` and assert HTTP 200. Either failure → return `{ error: "asset URL unreachable: <url>" }`.

### 7. Return

```
{ issueUrl, issueNumber, attachmentCount, assetsRef, assetsSha, notes? }
```

## Rules

- **Plan first, verbatim.** The issue body must start with `plan.md` content unmodified. `update-github-issue` re-pushes edits to this same body so the issue's revision history is the audit log.
- **Bundle everything.** The entire `<contextDir>/` (minus `outcome.md`) gets committed. No "this file is too small to bother" or "this is redundant" exceptions — the downstream worker decides what's relevant, not you.
- **Commits happen in the assets worktree, never the code worktree.** `cd <assetsWorkdir>` for every git operation in this skill. Touching `<workdir>` would leak assets into the eventual PR diff — that's the bug this whole design prevents.
- **Push target is the custom ref.** `git push origin HEAD:<assetsRef>`. Never push to a branch or tag. The ref lives in `refs/thk/*`, not `refs/heads/*` or `refs/tags/*`.
- **URLs use the commit SHA, never the ref name.** GitHub's blob/raw router won't resolve custom refs — SHA is the only stable form.
- **Every link must resolve.** The step-6 spot-check enforces this. A 404 image or 404 markdown link breaks the handoff contract and fails the skill.
- **Stage explicitly, never broadly.** Only `.github/thk-assets/<session-id>/` is staged. Never `git add .` or `git add -A`.
- **Privacy is a warning, not a block.** The caller knows whether the repo is public/private — you surface the risk (secret markers in `notes`) and proceed.
- **Atomic failure.** If any step after staging fails, unstage (`git reset HEAD`) in the assets worktree and return `{ error: "..." }`. Do not leave a half-committed state.
- **Pass content to `gh` with real newlines, not `\n` escapes.**
