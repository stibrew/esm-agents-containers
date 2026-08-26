# Review fanout playbook

This file is a playbook for the main orchestrator session — NOT a message to send to a subagent. The worker subagents cannot spawn subagents (their `task` permission is denied to keep the topology flat), so the parallel fanout below must be initiated from the main session.

Resolve context values (`DEFAULT_BRANCH`, `PLAN_FILE_PATH`, `PROGRESS_FILE_PATH`, review mode), then follow the instructions below from the main session: launch the specified parallel task tool calls, collect findings from all returned agents, and pass them to the `fixer` subagent. The orchestrator does NOT fix issues itself — the fixer is a separate subagent that handles fixes.

## How to fan out (READ THIS CAREFULLY)

In your NEXT assistant response, emit N task tool calls TOGETHER — all N must appear in the same response, no text between them, no pausing to read results. Multiple task tool calls in one response can run in parallel; task calls spread across separate responses run SEQUENTIALLY (Nx runtime). The agents are fully independent — no shared state, no ordering. After emitting all N tool calls, stop generating — the orchestrator response ends there, and your next response begins after all N return. (If the configured model serializes tool calls, the reviews still run correctly, just sequentially — do not change anything about the flow.)

The specialists' role instructions, READ-ONLY constraints, and severity-tagging rules are baked into their agent definitions (`.opencode/agents/reviewer-*.md`). Each invocation message only needs the per-run context. Use this message template for every reviewer (substitute the actual values):

```
Review mode: <comprehensive | critical-only>
Default branch: DEFAULT_BRANCH
Diff command: git diff DEFAULT_BRANCH...HEAD
Plan file: PLAN_FILE_PATH
Progress file: PROGRESS_FILE_PATH
<worktree instruction if in worktree mode: "Work ONLY inside <worktree_path> — cd there first.">
```

Do NOT embed diffs in the messages — each agent runs git commands itself. Embedding large diffs slows parallel launch and inflates context.

Severity categories (agents tag their own findings; findings without an explicit severity prefix are treated as MINOR):
- CRITICAL: bugs causing crashes, data loss, security holes, race conditions
- MAJOR: real correctness issues — incorrect behavior, missing error handling, broken contracts
- MINOR: style, doc drift, doc/code inconsistencies, nits, optional improvements

## Comprehensive mode (5 agents)

In your next assistant response, emit 5 task tool calls together, invoking: `reviewer-quality`, `reviewer-implementation`, `reviewer-testing`, `reviewer-simplification`, `reviewer-documentation` — each with the context message above (mode: comprehensive).

After ALL 5 agents return, produce a STRICT bullet-list report — no prose summary, no narrative, no "agents converge on" sentences. Format requirements:

- Group findings by severity in this order: CRITICAL, MAJOR, MINOR. Use a heading per severity (`### CRITICAL`, `### MAJOR`, `### MINOR`). Skip a severity heading if it has zero findings.
- Under each heading, one bullet per finding using EXACTLY this shape: `- <agent-name>: <file:line> — <description>`
- Preserve the original agent attribution (e.g. `quality`, `implementation`, `testing`, `simplification`, `documentation`). Do NOT rewrite as "agents" or "multiple agents".
- If two agents reported the same file:line + same issue, merge into one bullet and prefix both agent names separated by `+` (e.g. `- quality+implementation: main.go:12 — ...`).
- Do NOT verify, fix, or dismiss findings here — the fixer agent does that. Just emit the report verbatim from agent outputs.
- Omit agents that found nothing entirely (no need to mention them).
- After the bullet list, on its own line, emit one summary line: `Total: <N> findings (<C> critical, <M> major, <m> minor)`.

Do NOT add explanatory prose, recommendations, or commentary. The list goes straight to the fixer.

## Critical-only mode (2 agents)

In your next assistant response, emit 2 task tool calls together, invoking: `reviewer-quality` and `reviewer-implementation` — each with the context message above (mode: critical-only).

After BOTH agents return, produce the same STRICT bullet-list report as comprehensive mode (groupings by severity, exact bullet shape, agent attribution preserved, no prose summary). Additional rule for this mode:

- Drop any MINOR findings if agents returned them anyway. Only CRITICAL and MAJOR headings appear here.
- If neither agent reported CRITICAL or MAJOR findings, emit exactly: `Critical re-check: clean — no critical/major findings.` and stop.
