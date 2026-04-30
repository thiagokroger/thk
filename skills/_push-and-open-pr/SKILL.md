---
name: _push-and-open-pr
description: Push the current branch to origin and open a GitHub PR (Draft when `draft: true`). Reads the PR title and body **from files on disk** (`<contextDir>/pr-title.txt` and `<contextDir>/pr-body.md`, written by `_draft-pr-description`), not from agent-context strings. Preflights the files for emptiness and placeholder content; after `gh pr create`, reads the body back from GitHub and auto-corrects via `gh pr edit` if it landed truncated. Never force-pushes to `main`/`master`. Does NOT post Linear comments — Linear pings are reserved for cases where the Hand is blocked and needs human input (see `_request-more-info-on-linear`).
---

# Push and Open PR

Pure plumbing. Pushes the branch, opens the PR with the title + body composed by `_draft-pr-description`, verifies the body landed on GitHub, fixes it if it didn't.

**Why files, not strings.** A previous version of this skill accepted `prTitle` and `prBody` as inline string args expanded inside a heredoc by the dispatching agent. That worked fine for short titles but corrupted on long bodies when there was a 30+ minute gap between composition and dispatch (e.g., diff-phase meeting between Step 7b's `_draft-pr-description` and Step 7c's `_push-and-open-pr`). Symptoms: the PR body lands as `-`, as the literal `<prBody>` token, or as a truncated tail. The file-based handoff bypasses agent context entirely.

## Inputs

```
{
  workdir:     "<abs>",
  branchName:  "<name>",
  prTitlePath: "<abs — typically <contextDir>/pr-title.txt from _draft-pr-description>",
  prBodyPath:  "<abs — typically <contextDir>/pr-body.md from _draft-pr-description>",
  draft?:      boolean   // default false; thk's Step 7c passes true
}
```

## Output

```
{
  prUrl:        "<url>",
  bodyVerified: boolean,    // true if GitHub stored the full body on first try
  bodyCorrected: boolean    // true if we ran gh pr edit to fix a short-stored body
}
```

## Procedure

```bash
cd <workdir>

# --- Preflight: title + body files exist, non-empty, not placeholders ---
[ -f "<prTitlePath>" ] || error "prTitlePath does not exist: <prTitlePath>"
[ -s "<prTitlePath>" ] || error "prTitlePath is empty"
[ -f "<prBodyPath>"  ] || error "prBodyPath does not exist: <prBodyPath>"
[ -s "<prBodyPath>"  ] || error "prBodyPath is empty"

# Reject placeholder content. The body should be a real markdown PR body —
# at least a few hundred bytes — never a single dash or a literal token.
body_size=$(wc -c < "<prBodyPath>")
if [ "$body_size" -lt 100 ]; then
  error "prBodyPath is suspiciously small ($body_size bytes); refusing to open PR with degraded body. Re-dispatch _draft-pr-description."
fi

# Belt-and-suspenders: catch literal placeholder tokens that an earlier-
# version dispatch might have written.
first_chunk=$(head -c 200 "<prBodyPath>")
case "$first_chunk" in
  "-"|"<prBody>"*|"<prBody-from-context>"*|"<body>"*|"<the full markdown body"*)
    error "prBodyPath contains a placeholder, not a real body. Re-dispatch _draft-pr-description." ;;
esac

# --- Push the branch ---
git push -u origin "<branchName>"

# --- Open the PR ---
draft_flag=()
[ "<draft>" = "true" ] && draft_flag=(--draft)

# `gh pr create --body-file <path>` reads the file directly — no agent
# substitution, no heredoc, no quoting drama.
PR_TITLE=$(cat "<prTitlePath>")
pr_url=$(gh pr create "${draft_flag[@]}" --title "$PR_TITLE" --body-file "<prBodyPath>")

# --- Post-create verification ---
# Read the body back from GitHub and compare its byte length to the file we
# sent. Network or API hiccups occasionally land a truncated body; if that
# happened, re-edit immediately rather than letting the user discover it
# later.
expected_size="$body_size"
actual_size=$(gh pr view "$pr_url" --json body --jq '.body | length' 2>/dev/null || echo 0)

# Tolerance: GitHub canonicalizes line endings, so the stored body can be a
# byte or two off. Anything below 90% of expected is a real corruption.
threshold=$((expected_size * 90 / 100))

body_corrected=false
if [ "$actual_size" -lt "$threshold" ]; then
  echo "warning: PR body on GitHub is $actual_size bytes (expected ~$expected_size). Re-uploading via gh pr edit." >&2
  gh pr edit "$pr_url" --body-file "<prBodyPath>"
  # Re-read after correction; if still short, surface the failure.
  actual_size_after=$(gh pr view "$pr_url" --json body --jq '.body | length' 2>/dev/null || echo 0)
  if [ "$actual_size_after" -lt "$threshold" ]; then
    error "PR body still short after gh pr edit ($actual_size_after bytes). PR is open at $pr_url but the body is degraded — fix manually with: gh pr edit $pr_url --body-file <prBodyPath>"
  fi
  body_corrected=true
fi
```

Return:

```
{
  prUrl:         "$pr_url",
  bodyVerified:  true,
  bodyCorrected: <body_corrected>
}
```

## Rules

- **Files are the contract.** `prTitlePath` and `prBodyPath` are the canonical inputs. If a caller tries to pass `prTitle` or `prBody` as inline strings, return `{ error: "this skill requires file-based handoff via prTitlePath/prBodyPath; inline title/body args are not accepted (they corrupt across long context gaps). Have draft-pr-description run first to write the files." }`.
- **Preflight is non-negotiable.** A PR with `body=-` is worse than a failed dispatch: it ships, the human reviewer doesn't notice, and the chronicle linking back to the GH issue is lost. Refuse to open the PR rather than ship a degraded body.
- **Verify after create.** GitHub's API has been observed to accept-then-truncate on slow connections. Read the body back, compare lengths, re-edit if short. The cost is one extra `gh pr view` call — negligible compared to a wrong-body PR.
- **Never force-push, especially not to `main`/`master`.**
- **Never `--no-verify`.**
- **Never compose `prTitle` / `prBody` yourself.** If the files don't exist, fail — composition belongs to `_draft-pr-description`.
- If `gh pr create` fails (auth, no remote, existing PR for branch), surface the error verbatim.
- **Do not post a Linear comment.** PR-ready announcements are noise; the GitHub issue (already attached to the Linear ticket's Links panel by Step 4) carries the PR link, so a human glancing at the ticket finds the PR via Linear → GH issue → PR. Linear @-mentions are reserved for cases where the Hand is blocked and the human must act — see `_request-more-info-on-linear`.
