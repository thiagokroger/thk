---
name: _push-and-open-pr
description: Push the current branch to origin and open a GitHub PR (Draft when `draft: true`). Caller supplies `prTitle` and `prBody` — typically composed by the Grand Maester via `draft-pr-description` so this skill is pure plumbing. Optionally posts the PR URL as a Linear comment tagging the assigner. Never force-pushes to `main`/`master`.
---

# Push and Open PR

## Inputs
```
{
  workdir: "<abs>",
  branchName: "<name>",
  prTitle: "<title — typically from draft-pr-description>",
  prBody: "<markdown body — typically from draft-pr-description>",
  draft?: boolean,           // default false; thk's Step 6 passes true
  linearTicketUrl?: "<url>",
  assigner?: "<name>"
}
```

## Procedure

```bash
cd <workdir>
git push -u origin <branchName>
gh pr create \
  $( [ "<draft>" = "true" ] && printf -- '--draft ' ) \
  --title "<prTitle>" \
  --body-file <(cat <<'EOF'
<prBody>
EOF
)
```

The `--draft` flag is the only difference between a Draft PR and a regular PR — the title and body composition stays in the caller (Grand Maester via `draft-pr-description`). This skill never invents PR text.

If `linearTicketUrl` and `assigner` are both present, post a Linear comment via `mcp__linear__save_comment` tagging the assigner with the PR URL. Pass comment content with real newlines, not `\n`.

## Output
```
{ prUrl: "<url>" }
```

## Rules
- Never force-push, especially not to `main`/`master`.
- Never `--no-verify`.
- Never compose `prTitle` / `prBody` yourself. If the caller didn't pass them, return `{ error: "missing prTitle or prBody" }` — composition belongs to `draft-pr-description` (or whatever caller-side step authored the description).
- If `gh pr create` fails (auth, no remote, existing PR for branch), surface the error verbatim.
