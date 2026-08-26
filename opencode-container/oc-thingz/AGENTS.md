# AGENTS.md

Project instructions for opencode sessions in this template. Everything here applies to every agent session.

## What this repo is

An opencode template for running an "AI team": a plan → review → autonomous-execute → multi-agent review pipeline plus supporting skills, ported from umputun/cc-thingz (Claude Code) to opencode. Teams clone this repo, point `opencode.json` at their models, and work through the pipeline. See README.md and docs/ for the operating model.

- Model routing lives ONLY in `opencode.json` (tiers: worker = `model`, fast = `small_model`, reasoning = `plan`/`plan-review`, adversary = `adversary`). Agent files never name models — see docs/model-routing.md.
- Agent role definitions: `.opencode/agents/`. Skills: `.opencode/skills/`. Commands: `.opencode/commands/`. Project rule files: `.opencode/rules/`.
- The core loop: `brainstorm` (skill) → `/plan-make` → `plan-review` (agent) → `/plan-exec` (exec skill) → human review of the finalized branch.

## Mandatory skill activation

Before proceeding with any user request, check the available skills for relevance.

IF any skills are relevant:
1. State which skills and why (can be multiple)
2. Immediately activate ALL relevant skills via the skill tool
3. Then proceed with the task

IF no skills are relevant: proceed directly.

Example of multiple skills: user asks "review my changes since last release" → activate `last-tag` (release delta) and `git-review` (annotation review).

CRITICAL: Activate ALL relevant skills via the skill tool before implementation. Multiple skills can and should be activated when applicable. Mentioning a skill without activating it is worthless.

## Conventions

- Plans live in `docs/plans/`, finished plans in `docs/plans/completed/`.
- Worktrees created by the exec pipeline live in `.opencode/worktrees/` (gitignored).
- Progress files for exec runs live at `/tmp/progress-<plan-name>.txt`.
- Never modify the pipeline's own files (agents, skills, commands, scripts) as a side effect of running it. The only files workflows may write for rules management are under `.opencode/rules/`.
- Shell scripts must pass shellcheck; python scripts carry embedded tests runnable via `--test`.
- Tests live in `tests/` and run with `bash tests/test-<name>.sh`.

## For maintainers of this template

- `inspiration/` is the untouched upstream reference (MIT, umputun/cc-thingz) — never edit it; port from it.
- Every deviation from upstream behavior must be recorded in docs/porting-notes.md.
- Keep README.md up to date whenever a component is added or changed.
