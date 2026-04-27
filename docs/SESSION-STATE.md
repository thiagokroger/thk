# thk — session state inside the target repo

A concrete on-disk example of `<targetRepo>/.thk/` after three runs: one complex ticket that ran the full meeting flow to a Draft PR, one simple ticket that skipped the meeting, and one currently in progress.

```
<target-repo>/
├── .git/
├── .gitignore                              # contains `.thk/` (added by install.sh)
├── .thk/                                   # gitignored — never shows in `git status`
│   ├── config.json                         # written by install.sh — runner profile,
│   │                                       # ticket source, optional capture MCPs
│   ├── keys/                               # per-source secrets, chmod 700
│   │   └── jam.key                         # Jam personal access token, chmod 600
│   │
│   └── sessions/
│       │
│       ├── 2026-04-21_092312_eng-10105/    # COMPLEX ticket — meeting was convened
│       │   ├── progress.md                 # status: pr-drafted
│       │   ├── runtime-profile.json        # snapshot of the resolved profile
│       │   ├── log.md                      # ~200 lines: every dispatch / decision / error
│       │   ├── worktree/                   # nested git worktree on branch eng/10105-…
│       │   │   └── (full repo checkout)    # this is what became the Draft PR
│       │   ├── assets-worktree/            # orphan worktree on refs/thk/ENG-10105
│       │   │   └── .github/thk-assets/     # bundle commits — pushed to the custom ref
│       │   │       └── 2026-04-21_…/
│       │   │           └── context/        # mirror of the context/ folder below,
│       │   │                               # plus session-log.md
│       │   └── context/
│       │       ├── README.md               # entry-point index for the folder
│       │       ├── plan.md                 # the living plan (revised across the meeting)
│       │       ├── linear/
│       │       │   ├── ENG-10105.md        # primary ticket — full thread
│       │       │   └── ENG-10092.md        # linked ticket pulled by capture-linear
│       │       ├── jam/
│       │       │   └── jam-abc123def/
│       │       │       ├── details.md
│       │       │       ├── transcript.md
│       │       │       ├── analysis.md
│       │       │       ├── console.md
│       │       │       ├── network.md
│       │       │       ├── user-events.md
│       │       │       └── screenshots/
│       │       │           ├── 0.png
│       │       │           ├── 1.png
│       │       │           └── 2.png
│       │       ├── figma/
│       │       │   └── 12-3456/
│       │       │       ├── context.md
│       │       │       ├── metadata.json
│       │       │       ├── variables.json
│       │       │       └── screenshots/
│       │       │           └── 0.png
│       │       ├── planetscale/            # Grand Maester's DB lookup (his judgment)
│       │       │   └── user-by-email.md    # one targeted SELECT, redacted
│       │       └── plan-reviews/           # meeting flow → all four sub-folders populated
│       │           ├── round-1-plan/
│       │           │   ├── grand-maester.md
│       │           │   ├── master-of-laws.md
│       │           │   ├── lord-commander.md
│       │           │   └── master-of-coin.md
│       │           ├── round-2-plan/
│       │           │   └── counselor.md    # Codex (Counselor Altman) output
│       │           ├── round-1-diff/       # populated AFTER Step 5 execution
│       │           │   ├── grand-maester.md
│       │           │   ├── master-of-laws.md
│       │           │   ├── lord-commander.md
│       │           │   └── master-of-coin.md
│       │           ├── round-2-diff/
│       │           │   └── counselor.md
│       │           └── hand-decision.md    # 4 sections — Hand's verdicts on each round
│       │
│       ├── 2026-04-23_141502_eng-10210/    # SIMPLE ticket — no meeting
│       │   ├── progress.md                 # status: pr-drafted
│       │   ├── runtime-profile.json
│       │   ├── log.md
│       │   ├── worktree/                   # branch eng/10210-…
│       │   ├── assets-worktree/            # orphan worktree on refs/thk/ENG-10210
│       │   └── context/
│       │       ├── README.md
│       │       ├── plan.md
│       │       ├── linear/
│       │       │   └── ENG-10210.md
│       │       ├── jam/                    # empty — no Jam links in the ticket
│       │       ├── figma/                  # empty — no Figma links in the ticket
│       │       └── plan-reviews/           # no-meeting flow → ONE Counselor file only
│       │           └── counselor-pre-pr.md # single Codex Counselor pass on the diff
│       │
│       └── 2026-04-26_223045_eng-10311/    # IN PROGRESS — was at Step 5 when laptop slept
│           ├── progress.md                 # status: in-progress (last step done = 4)
│           ├── runtime-profile.json
│           ├── log.md
│           ├── worktree/                   # branch eng/10311-…
│           ├── assets-worktree/
│           └── context/
│               ├── README.md
│               ├── plan.md                 # already revised once after plan-phase meeting
│               ├── linear/ENG-10311.md
│               ├── jam/jam-xyz/
│               ├── figma/45-6789/
│               └── plan-reviews/           # meeting decided yes; only plan phase populated
│                   ├── round-1-plan/{four reviews}.md
│                   ├── round-2-plan/counselor.md
│                   └── hand-decision.md    # only Sections 1–2 written so far
│
└── (rest of the target repo: src/, package.json, etc. — untouched by thk)
```

## What's NOT in `.thk/` but lives elsewhere

| Artifact | Where |
|----------|-------|
| Each session's PR branch (`eng/10105-…`, etc.) | Pushed to origin under `refs/heads/` |
| Bundled `context/` per ticket — pinned forever | Pushed to origin under `refs/thk/<TICKET-CODE>` (not `refs/heads/`, not `refs/tags/` — invisible in branch picker / tags tab) |
| The GitHub issues themselves (one per ticket) | `github.com/<owner>/<repo>/issues/<n>` |
| The Draft PRs | `github.com/<owner>/<repo>/pull/<n>` |
| Linear `Hand of the King — <TICKET>` link | Linear ticket's Links panel |

## Visibility from the user's POV

- `git status` in the target repo: nothing thk-related (gitignored).
- `git worktree list`: each session's `worktree/` AND `assets-worktree/` show up — they're real git worktrees, just living inside an ignored directory. That's fine — they're not "untracked files", they're separate worktree checkouts of branches your repo already knows about.
- `git branch`: shows the session's PR branches (`eng/10105-…`) and the throwaway local branches the assets worktrees use (`_thk_assets_<TICKET-CODE>`). The latter never get pushed; only `refs/thk/<TICKET-CODE>` does.

## Cleanup behavior

- Sessions **persist by default**. The Hand doesn't auto-clean after `pr-drafted` — the session is your local audit trail.
- `_cleanup-session` is available but only runs when explicitly dispatched (rare today). It removes both worktrees and the session folder by default.
- The `refs/thk/<TICKET-CODE>` on origin **never** gets cleaned up by design — months later, anyone can `git fetch origin 'refs/thk/*:refs/thk/*'` and inspect any session's full bundled context at the exact commit SHA the GitHub issue references.
- Disk-size note: Jam/Figma screenshots are PNGs, so individual sessions can run 1–10 MB each. After dozens of sessions you might want to occasionally `rm -rf .thk/sessions/<old-ones>/` — it's safe (the GitHub side stays intact via the persistent custom ref).

**Worth keeping clean:** `.thk/keys/` — that's the only thing in `.thk/` that contains real secrets. `chmod 700` on the dir + `chmod 600` on each key file keeps them owner-readable only. Both `.thk/` and `.thk/keys/` are gitignored independently, so even if someone removes `.thk/` from `.gitignore` later, `.thk/keys/` and `*.key` are still excluded.
