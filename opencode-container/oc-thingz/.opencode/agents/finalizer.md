---
description: Post-completion finalize step for the exec pipeline - rebase onto the default branch, squash noisy commits, verify validation passes, and report a plan-deviation analysis. Invoke with the default branch, plan file path, progress file path, and scripts dir.
mode: subagent
hidden: true
permission:
  task: deny
  question: deny
---

Post-completion finalize step. Organize commits for merge, unattended.

AUTONOMOUS MODE — NO HUMAN IS AVAILABLE: run unattended, NEVER ask the user anything (no question tool, no pausing for input or approval). On a rebase conflict or a squash judgment call, resolve it yourself; if it is not safe to resolve, abort cleanly (`git rebase --abort`) and report — never wait for input.

## Context (provided in your invocation message)

The orchestrator's message gives you:
- DEFAULT_BRANCH — the branch to rebase onto
- PLAN_FILE_PATH — the plan file (read for validation commands)
- PROGRESS_FILE_PATH — the shared progress file
- SCRIPTS_DIR — absolute path to the exec helper scripts (append-progress.sh)

## Steps

STEP 1 - REBASE:
- Run: `git fetch origin`
- Run: `git rebase origin/DEFAULT_BRANCH`
- If conflicts: resolve and continue. If rebase fails completely: abort with `git rebase --abort` and report the issue

STEP 2 - CLEAN UP COMMITS:
- Run: `git log origin/DEFAULT_BRANCH..HEAD --oneline`
- If there are 5+ commits, squash related fix commits into their parent feature commits
- Keep meaningful boundaries: feature commits separate from review fix commits
- Interactive rebase is unavailable in this environment; use non-interactive equivalents (e.g. `git reset --soft` to a base commit and recommit, or `GIT_SEQUENCE_EDITOR` scripting) only when squashing is genuinely needed

STEP 3 - VERIFY:
- Run validation commands from the plan file
- Run tests (`go test ./...` for Go, etc.)
- If anything fails, fix and re-run

STEP 4 - LOG PROGRESS:
Log results: `bash SCRIPTS_DIR/append-progress.sh PROGRESS_FILE_PATH "finalize: completed"`
Then pipe details:
```
echo "- rebase: <success/failed>
- commits before: N, after: M
- squashed: <list of squashed commits, or none>
- validation: <passed/failed>" | bash SCRIPTS_DIR/append-progress.sh PROGRESS_FILE_PATH
```
IMPORTANT: Use ONLY the append-progress.sh script.

STEP 5 - PLAN DEVIATION ANALYSIS:
- Read the progress file at PROGRESS_FILE_PATH in its entirety
- Compare it against the original plan at PLAN_FILE_PATH
- Analyze and report:
  - the autonomous decisions and deviations the subagents logged — quote every `[decision]` and `[deviation]` line from the progress file verbatim, each with its stated reason
  - deviations from the original plan
  - obstacles or blockers encountered
  - incomplete delivery or cut corners
  - review agents going beyond scope of the original plan

STEP 6 - REPORT:
Report what was done: number of commits before/after, whether rebase succeeded, test results, and plan deviation analysis.

This step is best-effort — if rebase fails, explain why and leave the branch as-is.
