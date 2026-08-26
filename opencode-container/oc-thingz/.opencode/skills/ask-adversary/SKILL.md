---
name: ask-adversary
description: Consult the adversary agent (a different model family, configured in opencode.json) for a second opinion on investigation, debugging, or code review. Use when user explicitly asks to "ask the adversary", "second opinion", "cross-model review", "check with another model", or as a last resort when stuck after 4+ failed attempts at debugging, investigation, or bug fix and completely out of ideas. The adversary runs read-only with full project access — it analyzes, we implement.
---

# Ask Adversary

Consult the `adversary` subagent — deliberately bound to a DIFFERENT model family in opencode.json — as a second opinion for investigation, debugging, or review tasks. (This skill replaces cc-thingz's `ask-codex`, which shelled out to the OpenAI codex CLI; here the second opinion comes from whatever model the `adversary` agent is routed to, no extra CLI or account needed.)

## Activation Triggers

**Explicit:**
- "ask the adversary", "second opinion", "cross-model review"
- "what does another model think", "check with another model"
- "adversary review"

**Automatic (last resort — stuck detection):**
- 4+ failed attempts at the same bug fix or investigation
- completely out of ideas, all reasonable approaches exhausted
- going in circles with no progress despite multiple different strategies

## Workflow

### Step 1: Check Routing

The value of this skill is model diversity. Check `opencode.json` — if the `adversary` agent's model is the same family as the current session model, warn the user ("the adversary is currently routed to the same model family — the second opinion won't be independent; edit opencode.json to point it elsewhere") but proceed if they want.

### Step 2: Build Context

Gather context from the current conversation:

1. **What's the problem/question** — summarize in 2-3 sentences
2. **What we know** — relevant files, error messages, behavior observed
3. **What we tried** — approaches attempted and why they failed (if applicable)
4. **Specific question** — what exactly the adversary should analyze or answer

The adversary shares this project's instructions (AGENTS.md) automatically and its agent definition tells it to read `.opencode/rules/*.md` — no preamble hack needed.

### Step 3: Construct the Message

Build a focused message. Do NOT dump entire files — the adversary has read access to the whole project and can read them itself. Provide file paths and line references so it knows where to look.

**Template for investigation/debug (adversary Mode 2 — consultation):**

```
Consultation (Mode 2).

# [Investigation/Debug] Request

## Problem
[2-3 sentence description]

## Context
- Files: [path/to/file.go:lineNumber, ...]
- Observed: [what's happening]
- Expected: [what should happen]

## What We Tried
[List approaches and outcomes, or "First consultation" if fresh question]

## Question
[Specific, focused question to answer]

Provide:
1. Root cause analysis (if debugging)
2. Concrete recommendation with file:line references
3. Why previous approaches failed (if applicable)

Keep response focused and actionable.
```

**Template for code review (adversarial):**

When asked for a code review, use this adversarial message that requires structured JSON output:

```
<role>
You are performing an adversarial code review.
Your job is to break confidence in the change, not to validate it.
</role>

<task>
Review the provided changes as if you are trying to find the strongest reasons
this change should not ship yet.
Scope: [files and changes to review — paths, branch diff, or description]
Focus: [specific area if user specified one, otherwise "general"]
</task>

<operating_stance>
Default to skepticism.
Assume the change can fail in subtle, high-cost, or user-visible ways until
the evidence says otherwise. Do not give credit for good intent or partial fixes.
If something only works on the happy path, treat that as a real weakness.
</operating_stance>

<attack_surfaces>
Prioritize failures that are expensive, dangerous, or hard to detect:
- auth, permissions, tenant isolation, and trust boundaries
- data loss, corruption, duplication, and irreversible state changes
- rollback safety, retries, partial failure, and idempotency gaps
- race conditions, ordering assumptions, stale state, and re-entrancy
- empty-state, nil, timeout, and degraded dependency behavior
- version skew, schema drift, migration hazards, and compatibility regressions
- observability gaps that would hide failure or make recovery harder
</attack_surfaces>

<finding_bar>
Report only material findings. No style feedback, naming nitpicks, or speculative
concerns without evidence. Each finding must answer:
1. What can go wrong?
2. Why is this code path vulnerable?
3. What is the likely impact?
4. What concrete change would reduce the risk?
Prefer one strong finding over several weak ones.
</finding_bar>

<grounding_rules>
Every finding must be defensible from actual code you can see.
Do not invent files, lines, code paths, or runtime behavior you cannot support.
If a conclusion depends on an inference, state that explicitly and keep the
confidence score honest.
</grounding_rules>

<structured_output>
Return ONLY valid JSON. Example with concrete values:
{
  "verdict": "needs-attention",
  "summary": "auth middleware skips token validation on retry paths",
  "findings": [
    {
      "severity": "high",
      "title": "token validation bypassed on retry",
      "body": "retryHandler re-enters serveHTTP without revalidating the bearer token, allowing expired tokens through on transient failures",
      "file": "internal/auth/middleware.go",
      "line_start": 42,
      "line_end": 55,
      "confidence": 0.85,
      "recommendation": "move token validation before the retry loop entry point"
    }
  ],
  "next_steps": ["add test for expired-token retry scenario"]
}

Allowed values:
- verdict: "approve" or "needs-attention"
- severity: "critical", "high", "medium", or "low"
- confidence: 0.0 to 1.0

Use "needs-attention" if there is any material risk worth blocking on.
Use "approve" only if you cannot support any substantive finding.
</structured_output>
```

### Step 4: Invoke the Adversary

One task tool call invoking the `adversary` subagent with the constructed message. Strong reasoning models can take a while on deep analysis — that's expected; do not cancel early.

### Step 5: Present Results

1. **Extract the analysis** — skip any preamble or restated prompt
2. **Parse structured output** — for reviews, the adversary returns JSON; parse and present as structured findings
3. **Add your assessment** — agree, disagree, or note caveats
4. **STOP and ask** — do NOT apply any fixes or changes without explicit user approval

**For investigation/debug responses** (unstructured):

```
**Adversary Analysis:**

[response — cleaned up and formatted]

---

**Assessment:** [Your 2-3 sentence evaluation]

**Proposed action:** [What the adversary suggests — awaiting approval]
```

**For review responses** (structured JSON):

Parse the JSON output and present findings sorted by severity, filtered by confidence:

```
**Adversary Review: [verdict]**
[summary]

**Findings** (N issues):

1. **[critical]** title (confidence: 0.9)
   file.go:42-55
   [body]
   → [recommendation]

2. **[high]** title (confidence: 0.8)
   ...

**Next steps:** [list]

---

**Assessment:** [Your evaluation — which findings are valid, which are false positives]
```

- skip findings with confidence < 0.3 (likely noise)
- group by severity: critical → high → medium → low
- if verdict is "approve" and no findings, just say "the adversary found no material issues"

**CRITICAL: After presenting findings, STOP. Do not apply fixes, do not touch files, do not start implementing suggestions. Explicitly ask the user what to do next. Adversary findings are input for discussion, not automatic work orders.**

## Important Rules

- **Read-only always** — the adversary analyzes, we implement. Its agent definition denies edits.
- **Don't duplicate files** — the adversary has full project read access. Provide paths, not content.
- **Focused messages** — specific questions get better answers than broad "review everything".
- **One question at a time** — if multiple concerns, run separate adversary consultations.
- **Critical thinking** — any model can be wrong. Evaluate its suggestions before implementing.

## When NOT to Use

- Simple questions you already know the answer to
- Tasks where the solution is clear and just needs implementation
- File searches or codebase navigation (use grep/glob instead)

## Troubleshooting

- **Same-family warning**: edit the `adversary` entry in `opencode.json` to a different provider/model — see docs/model-routing.md
- **Provider auth errors**: `opencode auth login` for the provider the adversary is routed to
- **Off-target response**: refine the message with more specific file:line references
