---
name: _commit-changes
description: Stage specific files by explicit path and create a commit. Reads the repo's last 20 commits to match the existing message format. Never `git add .`, never `--amend`, never `--no-verify`.
---

# Commit Changes

## Inputs
```
{
  workdir: "<abs>",
  commitMessage: "<text>",
  files: string[]          // explicit files to stage
}
```

## Procedure

1. `cd <workdir>`.
2. `git log --oneline -20` — match the repo's existing commit-message style / tone.
3. `git status` — confirm the intended files are actually modified.
4. `git add <file1> <file2> ...` — stage by explicit path only.
5. Commit via HEREDOC:
   ```bash
   git commit -m "$(cat <<'EOF'
   <commitMessage>
   EOF
   )"
   ```

## Output
```
{ commitSha: "<sha>" }
```

## Rules
- Never `git add .` or `git add -A`.
- Never `--amend`. If a pre-commit hook fails, return `{ error: "<hook output>" }` — do not retry with `--no-verify`.
- No `Co-Authored-By` line.
