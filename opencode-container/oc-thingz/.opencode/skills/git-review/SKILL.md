---
name: git-review
description: Interactive git diff annotation review. Generates a cleaned-up diff file the user annotates in their own editor, then addresses the feedback in a loop. Activates on "git review", "review changes", "review my changes", "annotate changes", "interactive review".
---

# Git Review

Interactive annotation-based code review using a shared review file.

## Activation Triggers

- "git review", "review changes", "review my changes"
- "annotate changes", "interactive review"
- "review diff", "annotate diff"

## How It Works

1. Script generates a cleaned-up diff file (friendly headers, no technical noise) and prints its path
2. The user opens that file in their OWN editor, adds annotations (comments, change requests) directly in the file, saves, and tells you "done"
3. Script returns the user's annotations as a git diff
4. You read the annotations and fix code in the real repo
5. Script regenerates a fresh diff (reflecting fixes); user annotates again
6. Loop until the user has no more annotations

(The upstream cc-thingz version opened the editor itself via a terminal overlay; this port uses a prepare/collect flow instead — see the two script phases below.)

## Workflow

### Step 1: Prepare the review file

```bash
python3 .opencode/skills/git-review/scripts/git-review.py --prepare [base_ref]
```

- No base_ref: auto-detects uncommitted changes or branch vs default branch
- With base_ref: diffs against the specified ref (branch, tag, commit, `HEAD~3`)

The script prints the review file path. Tell the user: "Review file ready at `<path>` — open it in your editor, annotate directly in the file (add comments next to the code, or edit lines to show what you want changed), save, and say 'done'."

### Step 2: Collect annotations

When the user says they're done:

```bash
python3 .opencode/skills/git-review/scripts/git-review.py --collect
```

If the command produces output (stdout), the user made annotations. The output is a git diff showing what the user added/changed in the review file.

Read the diff carefully:
- **Added lines (+)**: user's annotations, comments, or change requests
- **Removed lines (-)**: user wants something removed or changed
- **Modified lines (- then +)**: user replaced text to show desired change

Each annotation is in context — the surrounding `===` file headers and diff content show which file and code area the annotation refers to.

### Step 3: Plan changes

Before modifying any code, present a short plan and get approval:
- list each annotation and which file/code area it refers to
- describe the planned changes for each annotation
- get user approval before modifying any code (for larger rounds, suggest the plan agent — Tab)

### Step 4: Address annotations

After approval, fix the actual source code in the real repository.
Each annotation is a directive — treat it as a code review comment that must be addressed.

### Step 5: Loop

After fixing code, run `--prepare` again. It regenerates a fresh diff reflecting the fixes. The user can:
- Add more annotations → go back to step 2 (plan + fix again)
- Say done without editing → `--collect` produces no output → review complete

### Step 6: Done

When `--collect` produces no output, the review is complete. Inform the user.

## Script Arguments

| Argument | Description |
|----------|-------------|
| `--prepare [ref]` | generate/refresh the review file; auto-detects uncommitted changes if no ref given |
| `--collect` | print the user's annotations as a git diff (empty when none) |
| `--branch <name>` | review a branch without checking it out (pass to both phases) |
| `--clean` | remove the review tracking repo from /tmp |
| `--test` | run embedded unit tests |

## Example Session

```
User: "review my changes"
→ run: git-review.py --prepare
→ "Review file ready at /tmp/git-review-myproj-feature/review.diff — annotate and say done"
→ user adds "this should validate input" next to a handler, saves, says "done"
→ run: git-review.py --collect → shows the annotation
→ plan: "annotation requests input validation in handler.go, plan: add validate() call"
→ user approves plan
→ add input validation to the handler
→ run: git-review.py --prepare (again) → user reopens, closes without changes, says "done"
→ --collect: no output → review complete
→ "review complete, all annotations addressed"
```

## Requirements

- git
- any editor the user likes (nothing is launched for them)
