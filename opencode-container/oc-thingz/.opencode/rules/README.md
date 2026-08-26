# Custom Rules

Custom rules let you inject project-specific conventions into the workflows in this template (plan-make, exec, plan-review, brainstorm). Rules are free-form markdown loaded at invocation time and applied as additional instructions alongside each component's built-in behavior.

## File Locations

Rules live in this directory, one file per workflow:

- `.opencode/rules/planning-rules.md` — planning workflow (plan-make, exec, plan-review)
- `.opencode/rules/brainstorm-rules.md` — brainstorm skill

For teams migrating from cc-thingz on Claude Code, the legacy locations `.claude/planning-rules.md` / `.claude/brainstorm-rules.md` are still checked as a fallback when no file exists here. Empty files are treated as absent.

## Resolution

Each component runs `bash .opencode/scripts/resolve-rules.sh <filename>` at startup. The script outputs the first non-empty file found (`.opencode/rules/` first, legacy `.claude/` second) or empty output if neither exists. First-found-wins — files are never merged.

## Managing Rules

Ask in a session (the plan-make command and brainstorm skill handle these):

- **show rules** — displays current rules
- **add/update rules** — writes to the file in `.opencode/rules/`
- **clear rules** — deletes the file

Or just edit the files here directly and commit them — this template repo is the distribution unit, so committed rules apply to the whole team.

## Example Content

```markdown
## testing conventions
- use table-driven tests with testify
- mock external dependencies with moq
- aim for 80% coverage minimum

## naming
- use camelCase for local variables
- keep function names under 30 characters

## plan structure preferences
- max 5 checkboxes per task
- always include rollback steps for migrations
```

## How Rules Apply

- **plan-make**: rules influence plan structure, testing approach, naming conventions, task granularity
- **plan-review**: rules become additional review criteria for convention adherence
- **exec**: rules propagate to task subagents via the `USER_RULES` placeholder in task prompts
- **brainstorm**: rules influence design preferences, naming conventions, technology choices

Rules supplement built-in instructions — they never replace them.
