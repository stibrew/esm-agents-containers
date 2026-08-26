---
name: exec
description: "Execute plan tasks sequentially using subagents. Use when user says 'exec', 'execute plan', 'run plan', or wants to implement a plan file task by task with isolated subagents, followed by multi-agent review phases and finalize."
---

# exec

Execute plan file tasks sequentially, each in an isolated subagent, then run multi-phase reviews (comprehensive fanout → smells → cross-model adversary → critical-only), finalize, and report.

## Arguments

- The invocation may include a path to a plan file (optional; if omitted, ask user to pick from the plans directory, default: `docs/plans/`)

## Configuration

There is no external config for this skill — these defaults are edited here, in this file (this template repo is the distribution unit):

| Setting | Default | Meaning |
|---|---|---|
| `task_retries` | 1 | retries per failed task before aborting |
| `review_iterations` | 5 | max iterations of review phase 1 |
| `adversary_iterations` | 10 | max iterations of the adversary review loop |
| `finalize_enabled` | true | run the finalize (rebase/squash) phase |
| `plans_dir` | `docs/plans` | where plan files live |

## Subagents used

All heavy lifting runs in the named subagents defined in `.opencode/agents/` (invoked via the task tool). Their role instructions are baked into the agent definitions; you only pass a short context message:

- `task-executor` — implements one task section
- `reviewer-quality`, `reviewer-implementation`, `reviewer-testing`, `reviewer-simplification`, `reviewer-documentation`, `reviewer-smells` — read-only review specialists
- `adversary` — independent cross-model reviewer (configured in opencode.json to run on a different model family)
- `fixer` — verifies findings and fixes confirmed ones
- `finalizer` — rebase/squash/verify

To customize a role's behavior, edit its agent file in `.opencode/agents/` and commit. Prompt templates under `references/` resolve through `resolve-file.sh` and can be overridden per-project in `.opencode/exec-plan/`.

## File Resolution

ALWAYS use the resolve script to read prompt template files. NEVER construct the override chain manually:
```
bash .opencode/skills/exec/scripts/resolve-file.sh prompts/review-playbook.md
bash .opencode/skills/exec/scripts/resolve-file.sh prompts/adversary-review.md
```
The script checks the project override (`.opencode/exec-plan/<path>`) then the bundled default.

### Context values for subagent messages

At the start of the run, compute these once and substitute them into every subagent invocation message (subagents run in fresh contexts and know none of this):

- `SCRIPTS_DIR` — absolute path to `.opencode/skills/exec/scripts` **in the tree where the run executes** (main dir or worktree)
- `PLAN_FILE_PATH` — absolute path to the plan file
- `PROGRESS_FILE_PATH` — the progress file path
- `DEFAULT_BRANCH` — from detect-branch.sh
- `USER_RULES` — resolved custom rules content (see below), or empty
- phase-specific values (`FINDINGS`, `DIFF_COMMAND`, review mode)

## Custom Rules Loading

Before starting execution, run this command via bash to check for user-provided custom rules:

```bash
bash .opencode/scripts/resolve-rules.sh planning-rules.md
```

If the output is non-empty, store it as the resolved custom rules content. When substituting `USER_RULES` in task-executor messages, wrap the content with a label so the subagent understands it: use "ADDITIONAL CUSTOM RULES:\n<content>" as the substitution. If the output is empty, substitute an empty string. See `.opencode/rules/README.md` for full documentation on the rules mechanism.

## Process

### Step 1. Resolve plan file

If the invocation contains a file path, use it. Otherwise, list `.md` files in the plans directory (default: `docs/plans/`), excluding `completed/`. If exactly one plan found, use it automatically. If multiple found, ask the user to pick one via the question tool.

Read the plan file. Count total Task sections (`### Task N:` or `### Iteration N:`) to know the scope.

Determine the default branch: `bash .opencode/skills/exec/scripts/detect-branch.sh`

Note: in `hg` repos, detect-branch.sh returns `remote/<name>` (checking `master`, `main`, `trunk` in that order) in modern-Mercurial repos that expose upstream default via `remote/<name>` refs, and falls back to `default` in repos that use the traditional named-branch convention instead. The adversary-review prompt and the finalizer use git-specific commands and are skipped on hg (see steps 9 and 11, which re-detect VCS locally). Users who want hg-native review/finalize can override `prompts/adversary-review.md` via `.opencode/exec-plan/` and edit `.opencode/agents/finalizer.md` — any `git rebase origin/DEFAULT_BRANCH` must be replaced with the hg equivalent, e.g. `hg rebase -d remote/master` when the repo exposes remote-tracking refs, or `hg rebase -d default` in the named-branch convention.

### Step 2. Ask about worktree isolation

**hg skip**: Detect VCS with `vcs=$(bash .opencode/skills/exec/scripts/detect-vcs.sh)`. If `vcs` is `hg`, skip the worktree question and proceed in current directory. Worktree isolation is git-only; users who want isolation in hg repos can use `hg share` manually before invoking exec.

First detect current branch state — run `git branch --show-current` and compare with the default branch detected earlier (from `detect-branch.sh`). Two cases:

**Case A — currently on the default branch (master/main/trunk).** Step 4 will create a new feature branch. Ask the user via the question tool: "Where should the feature branch be created?" with options:

- **Worktree (isolated)** — "Create the feature branch in a new isolated git worktree (under .opencode/worktrees/). Main working directory stays on the default branch."
- **In-place** — "Create the feature branch in this working directory. Main directory switches to the feature branch for the duration of the run."

**Case B — currently on a feature branch.** Step 4 will keep using this branch. Ask via the question tool: "You're already on a feature branch. Run the plan here, or in an isolated worktree?" with options:

- **Stay here** — "Run the plan in this working directory, on the existing feature branch."
- **Move to worktree** — "Copy this branch into a new isolated git worktree (under .opencode/worktrees/). Main directory stays untouched."

In BOTH cases: ask the question **now**, do not generate text first, do not skip, do not assume — the choice affects the user's working directory and the orchestrator cannot decide on their behalf.

**If the user picks "Worktree (isolated)" or "Move to worktree"** — the main working directory MUST NOT be touched at all: no branch is created or checked out there, and no file changes land there. That isolation is the entire point of this mode. Set `worktree_mode = true` and do this:

1. Record the main tree's path and current branch so you can verify it stayed untouched: `main_tree=$(git rev-parse --show-toplevel)` and `main_branch=$(git branch --show-current)`.
2. Derive the feature branch name with NO git side effects: `name=$(bash .opencode/skills/exec/scripts/create-branch.sh --print-name <plan-file-path>)`.
3. Create the isolated worktree: `git worktree add .opencode/worktrees/<name> -b <name>` (in Case B, where the feature branch already exists and is checked out here, instead use `git worktree add .opencode/worktrees/<name> HEAD -b <name>-wt` and then inside the worktree rename with `git -C .opencode/worktrees/<name> branch -m <name>-wt <name>` only if `<name>` is not already taken; if the current branch IS `<name>`, keep the worktree on a detached copy and rename the run branch to `<name>-run`). Capture the worktree's absolute path as `worktree_path`.
4. **This means Step 4 (create-branch.sh) is SKIPPED** — the branch already exists inside the worktree. Running create-branch.sh here would `git checkout -b` in the main tree and break isolation.
5. **Isolation guard**: verify the main tree is untouched — `git -C "$main_tree" branch --show-current` MUST still equal `main_branch`. If it changed, STOP and report the isolation breach instead of continuing.
6. Every later step (task execution, reviews, finalize, stats, the plan move) runs inside the worktree: prefix your own git/bash commands with the worktree path (`git -C <worktree_path>` or `cd <worktree_path> &&`), recompute `SCRIPTS_DIR` and `PLAN_FILE_PATH` as worktree-absolute paths, and tell every subagent in its invocation message: "Work ONLY inside <worktree_path> — cd there first; never touch <main_tree>." At completion, report `worktree_path` and the branch name so the user can review and merge.

**If the user picks "In-place" or "Stay here"** — set `worktree_mode = false` and proceed normally; Step 4 creates the branch in this working directory.

### Step 3. Create task list

ALWAYS create todos using the todowrite tool before starting any work. Create one todo per plan Task section plus review phases:

- one todo per `### Task N:` section: "Task N: <title>"
- "Review phase 1: comprehensive" (5 parallel review agents + fixer)
- "Review phase 2: code smells" (smells agent + fixer)
- "Review phase 3: adversary cross-model review" (adversarial review loop)
- "Review phase 4: critical only" (2 review agents + fixer)
- "Finalize" (rebase, clean up commits, verify)
- "Stats summary" (wall-clock/phase/git stats from the progress file)

Update todos as you go: mark in_progress when starting, completed when done.

### Step 4. Create branch

**Skip this step entirely when `worktree_mode` is true** — Step 2 already created the branch inside the isolated worktree, and running this here would `git checkout -b` in the main working tree and break isolation. Carry the branch name forward and go to Step 5.

Otherwise (in-place mode), **MANDATORY**: run the script below. Do NOT create the branch manually — the script strips the date prefix from the plan filename (e.g., `20260329-feature-name.md` → branch `feature-name`).

```
bash .opencode/skills/exec/scripts/create-branch.sh <plan-file-path>
```

The script creates a feature branch if currently on main/master, or stays on the current branch if already on a feature branch. Capture and use the branch name it outputs.

### Step 5. Initialize progress file

Initialize the progress file: `bash SCRIPTS_DIR/init-progress.sh /tmp/progress-<plan-name>.txt <plan-file-path> <branch-name>` (derive `<plan-name>` from the plan file stem, e.g., `fix-issues.md` → `progress-fix-issues`). The script creates the file with a header. Report the full progress file path to the user.

IMPORTANT: Always use `SCRIPTS_DIR/append-progress.sh` to write to the progress file after initialization. Never write directly.

See `references/prompts/progress-file.md` for the full format and when to write.

### Step 6. Task loop

Repeat until no `[ ]` checkboxes remain in any Task section:

1. **Re-read the plan file** (subagent modifies it each iteration)
2. **Find the first Task section** (`### Task N:` or `### Iteration N:`) that still has `[ ]` checkboxes
3. **If none found** — all tasks complete, go to step 7
4. **Announce the task to the user** — before spawning the subagent, output a visible summary:
   - Task number and title (from the `### Task N:` header)
   - List all `[ ]` checkbox items in that task section
   - Example output:
     ```
     --- Task 1: Fix error handling ---
     - [ ] Handle the error from os.ReadFile
     - [ ] Either log and exit or handle gracefully
     ```
5. **Spawn the task-executor subagent** — one task tool call invoking `task-executor` with a message containing: `PLAN_FILE_PATH`, `PROGRESS_FILE_PATH`, `SCRIPTS_DIR`, `USER_RULES` (labelled, or omitted if empty), the worktree instruction when in worktree mode, and — on a retry — the error details from the failed attempt so it can fix them
6. **After subagent returns**, re-read the plan file and check if that task's checkboxes are now `[x]`
   - If yes — task succeeded, continue loop
   - If no — **retry** with a fresh subagent for the same task up to `task_retries` times (default: 1). If all retries fail, stop and report failure to user
7. **Report to user**: "Task N completed" (one line). The task subagent logs details to the progress file.

CRITICAL: Spawn exactly ONE task subagent per iteration and WAIT for it to return before starting the next. NEVER batch-spawn multiple task subagents in a single message. Plan tasks are ordered and interdependent — later tasks build on the files earlier tasks create, and every task subagent edits the same plan-file checkboxes and overlapping source files, so running them in parallel corrupts the plan and the working tree. The "launch in a single message for parallel execution" instruction applies ONLY to the review phases (steps 7 and 10), never to this task loop.

CRITICAL: Do NOT stop the loop based on subagent return text. The ONLY condition to stop is: no `[ ]` checkboxes remain in any Task section (`### Task N:` or `### Iteration N:`). Always re-read the plan file to check.

CRITICAL: You are the ORCHESTRATOR. Never read code, debug errors, investigate diagnostics, or fix issues yourself. If a subagent leaves problems (compiler errors, test failures, lint issues), retry with a fresh subagent — pass the error details in the prompt so it can fix them. All code work happens inside subagents, not in the orchestrator.

Maximum iterations safety limit: 50. If reached, stop and report to user.

### Step 7. Review phase 1 — comprehensive then critical re-check

After all tasks complete, run a comprehensive code review on iteration 1, then narrow to critical-only re-checks on subsequent iterations to verify the fixer's work without re-running the full heavy sweep.

Report to user: "--- Review phase 1: comprehensive ---"

Loop up to `review_iterations` times (default: 5). Track the current iteration number:

1. **Read the fanout playbook** — resolve `prompts/review-playbook.md` through the override chain and follow it FROM THIS SESSION. It tells YOU (the orchestrator) how to fan out the review agents and how to format the findings report.
   - **Iteration 1**: comprehensive mode — launch 5 review agents in parallel (`reviewer-quality`, `reviewer-implementation`, `reviewer-testing`, `reviewer-simplification`, `reviewer-documentation`)
   - **Iteration 2 and later**: critical mode — launch 2 review agents in parallel (`reviewer-quality`, `reviewer-implementation`) focused on critical/major issues only. Before this iteration, report to user: "--- Review phase 1: critical re-check (iteration N) ---"

2. **Collect findings** — collect findings from ALL launched review agents and assemble the strict report per the playbook. Pass the COMPLETE output (not a summary) to the fixer. Do NOT summarize, filter, or dismiss any findings. ALL findings are actionable. Report to user with a short list of findings. Log to progress file:
   `bash SCRIPTS_DIR/append-progress.sh <progress-file> "review phase 1: findings"`
   Then pipe: `echo "<findings>" | bash SCRIPTS_DIR/append-progress.sh <progress-file>`

3. **If ALL agents reported zero issues** → report "Review phase 1: clean" and proceed to the next phase.

4. **Spawn the fixer subagent** — one task tool call invoking `fixer` with a message containing the FULL unedited review output as FINDINGS, plus `PLAN_FILE_PATH`, `PROGRESS_FILE_PATH`, `SCRIPTS_DIR` — the fixer decides what's real, not you.

5. **After fixer returns** → show the "FIXES:" section to the user. Report "Review phase 1: iteration N fixes applied". Loop back to step 1.

If `review_iterations` reached with issues still found, report "Review phase 1: max iterations reached, moving on" and continue.

### Step 8. Review phase 2 — code smells

Report to user: "--- Review phase 2: code smells analysis ---"

Run once (no loop):

1. **Spawn the smells subagent** — one task tool call invoking `reviewer-smells` with the standard review context message (DEFAULT_BRANCH, diff command, PLAN_FILE_PATH, PROGRESS_FILE_PATH, comprehensive mode).

2. **Collect findings** — after the agent returns, report to user with a compact list of findings (one line per finding). Log findings to progress file:
   `bash SCRIPTS_DIR/append-progress.sh <progress-file> "review phase 2: findings"`
   Then pipe the findings: `echo "<findings>" | bash SCRIPTS_DIR/append-progress.sh <progress-file>`

3. **If no issues found** → report "Smells analysis: clean" and proceed to the next phase.

4. **Spawn the fixer subagent** — same as phase 1, passing the FULL smells output as FINDINGS.

5. **After fixer returns** → report fixes to user. Proceed to the next phase.

### Step 9. Review phase 3 — adversary cross-model review

**hg skip**: Detect VCS with `vcs=$(bash SCRIPTS_DIR/detect-vcs.sh)`. If `vcs` is `hg`, skip this entire step. Report to user: "hg detected — skipping adversary review (git-only). Override `prompts/adversary-review.md` via `.opencode/exec-plan/` to enable hg-native review." Proceed directly to step 10.

Report to user: "--- Review phase 3: adversary cross-model review ---"

Adversarial loop: the `adversary` subagent — configured in opencode.json to run on a DIFFERENT model family than the workers — reviews the code, the fixer evaluates and fixes, the adversary re-reviews. The loop exits early once an iteration produces no `CRITICAL` or `MAJOR` findings — minor-only iterations still get fixed by the fixer, but no further adversary round-trip happens. Subsequent phases (critical-only) act as the final safety net.

Loop up to `adversary_iterations` times (default: 10):

1. **Resolve the adversary message** — read `prompts/adversary-review.md` through the override chain. Replace `DIFF_COMMAND`: iteration 1 is `git diff DEFAULT_BRANCH...HEAD` and subsequent iterations are `git diff`. Also replace `PLAN_FILE_PATH` (so the adversary can read the plan for intent) and `PROGRESS_FILE_PATH` (so it can read prior review iterations and fixer responses and avoid re-reporting fixed issues).

2. **Spawn the adversary** — one task tool call invoking `adversary` with the resolved message.

3. **Check adversary output** — if it reports "NO ISSUES FOUND" or equivalent, phase is done. Proceed to step 10.

4. **Classify severity** — scan the output for `CRITICAL` or `MAJOR` markers (case-insensitive whole-word match). Set `has_blocking = true` if either is present, otherwise `has_blocking = false`. Findings without an explicit severity tag are treated as MINOR — `has_blocking` stays false in that case.

5. **Report adversary findings to user** — show a compact list (one line per finding).

6. **Spawn the fixer subagent** — same as other review phases, passing the adversary output as FINDINGS. Fixer verifies, fixes, commits, reports FIXES.

7. **Report fixer results to user** — show FIXES section. Log to progress file.

8. **Decide whether to loop**:
   - If `has_blocking` is false → report "Adversary review: only minor findings — fixes applied, stopping loop" and proceed to step 10.
   - Otherwise → loop back to step 1.

If `adversary_iterations` reached with critical/major issues still found, report "Adversary review: max iterations reached, moving on" and continue.

### Step 10. Review phase 4 — critical only

Report to user: "--- Review phase 4: critical/major only (single pass) ---"

Same structure as step 7 but in critical mode from the start. Follow the `review-playbook.md` critical mode FROM THIS MAIN SESSION — launch 2 review agents in parallel (`reviewer-quality`, `reviewer-implementation`) focusing on critical/major issues only. Same fixer flow — pass findings to fixer, show FIXES to user.

### Step 11. Finalize

**hg skip**: Detect VCS with `vcs=$(bash SCRIPTS_DIR/detect-vcs.sh)`. If `vcs` is `hg`, skip this entire step. Report to user: "hg detected — skipping finalize (git-only). Edit `.opencode/agents/finalizer.md` to enable hg-native finalize." Proceed directly to step 12.

Check `finalize_enabled` (default: true, see Configuration). If false, skip this step.

After all reviews pass, rebase and clean up commits.

Report to user: "--- Finalize: rebase and clean up commits ---"

Spawn one task tool call invoking `finalizer` with a message containing `DEFAULT_BRANCH`, `PLAN_FILE_PATH`, `PROGRESS_FILE_PATH`, and `SCRIPTS_DIR`.

This is best-effort — if rebase fails, report the issue but don't block completion.

### Step 12. Stats summary

After finalize (or after step 11 was skipped on hg/disabled), produce a compact run summary YOURSELF from the progress file and git — do not spawn an agent for this:

1. Read the progress file. Timestamps on `[...]`-prefixed lines (written by append-progress.sh) give you: run start (`Started:` header), each task's completion time, each review phase boundary, and completion. Compute wall-clock total and rough per-phase durations from consecutive timestamps.
2. Count fixer iterations per phase from `[fixer]`/findings entries; note the adversary exit reason (clean / minor-only early exit / max iterations).
3. Run `git diff --shortstat DEFAULT_BRANCH...HEAD` for total churn, `git diff --stat DEFAULT_BRANCH...HEAD | head -10` and pick top 5 files by churn, `git log --oneline DEFAULT_BRANCH..HEAD | wc -l` for commit count.
4. Emit ONLY this markdown report:

```
## Run summary

**Wall-clock:** <Xm Ys>   **Tasks:** <N>   **Review iterations:** phase 1: <N>, adversary: <N>

### Per-phase (approx, from progress timestamps)

| Phase | Wall |
|---|---|
| Task loop | <...> |
| Review phase 1 | <...> |
| ... |

### Branch changes (vs DEFAULT_BRANCH)

<N> files changed, +<adds> / -<dels>
Commits on branch: <N>

Top files by churn:
- <file>  +<adds>/-<dels>

### Notable

- Adversary severity exit: <yes/no, reason>
- Fixer iterations: phase 1: <N>, phase 4: <N>, smells: <N>, adversary: <N>
- Final state: <completed | max-iter-hit | aborted>
```

Note: per-agent token accounting is not available here (the upstream cc-thingz stats agent parsed Claude Code session transcripts; opencode has no equivalent path wired in — use `opencode stats` in the TUI for session-level usage). If a value has no data, write "n/a" rather than omitting the line.

This step is best-effort — if the progress file is unreadable, report the failure but do not block completion.

### Step 13. Completion

When the stats summary is done (or skipped on failure):
- **Report autonomous decisions and deviations to the user.** The run had no human to answer questions, so subagents decided judgment calls themselves and logged them. Collect every such entry from the progress file — `grep -E '\[(decision|deviation)\]' <progress-file>` — and present them in a dedicated section titled **"Decisions made autonomously / Deviations from the plan"**, one bullet per entry with its stated reason, so the user learns every question the run answered on its own and why. If there are none, state "no autonomous decisions or deviations were logged." Do this regardless of whether finalize ran — finalize is skipped on hg or when disabled, so this is the guaranteed place the user always gets the report.
- Log completion to progress file: `bash SCRIPTS_DIR/append-progress.sh <progress-file> "completed"`
- Move the finished plan into its `completed/` subdirectory and commit it (best-effort): `bash SCRIPTS_DIR/move-plan.sh <plan-file-path>`. The script is a no-op when the plan is already under `completed/` or missing, derives the target as a `completed/` sibling of the plan's directory (so it respects a custom plans dir and worktrees), and commits the move VCS-aware (git/hg). Do NOT push. If the script exits non-zero, report the failure but do not block completion.
- Report the final line "All N tasks completed, reviews passed, branch finalized". Append ", plan moved to completed/" ONLY when move-plan.sh actually moved the file (it printed `moved plan to ...`); omit the suffix when the move was a no-op (already under `completed/` or missing) or exited non-zero

## Key rules

- Each subagent gets a fresh context — no accumulated state from previous tasks. Substitute ALL context values into every invocation message
- Parent session only tracks: task number, success/failure, retry count
- Plan file is the single source of truth for progress — always re-read it
- No signals — just checkboxes in the plan for task progress
- Maintain progress file (`/tmp/progress-<plan-name>.txt`) — see `references/prompts/progress-file.md` for format and when to write
- Do not modify the plan file yourself during the task, review, and finalize phases — only subagents modify it. The sole exception is the terminal move in step 13 (after all phases finish), which the orchestrator performs via `move-plan.sh`
- Do not implement or fix code yourself — only subagents implement and fix
- If a subagent fails or leaves broken code, re-run the loop — do NOT investigate or fix it yourself
- NEVER dismiss findings as "pre-existing", "not from changes", or "architectural" — ALL findings are actionable
- NEVER summarize or filter agent findings — pass the full output to the fixer agent verbatim
- Prompt template files (`references/prompts/*`) MUST be resolved through the override chain (resolve-file.sh) before use
- Review fanout is ALWAYS initiated from this orchestrator session — the worker subagents cannot spawn subagents themselves (their `task` permission is denied by design to keep the topology flat and debuggable)
- Subagents run with NO human available — they must NEVER ask the user a question (their question tool is denied; their agent definitions repeat this). They decide judgment calls the plan does not settle from the project's lint rules, AGENTS.md, and code conventions, and log each as a `[decision]`/`[deviation]` line for the completion report
- In worktree mode (`worktree_mode = true`) the main working directory is never touched — no branch is created or checked out there and no changes land there; all git operations run inside the worktree, and Step 4's create-branch.sh is skipped
