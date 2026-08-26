---
name: learn
description: Update project AGENTS.md with strategic knowledge discovered during this session — or AGENTS.local.md when the discovery is per-developer/per-checkout and that file already exists. Defers to any project-defined memory-placement guidance instead of overriding it. Use when user says "learn", "save knowledge", "update agents.md", "capture learnings", or at end of significant work sessions.
---

# Learn

Review the current conversation history and identify strategic, reusable project knowledge that should be captured in the project AGENTS.md file. When the project has opted into a three-tier memory convention by creating `AGENTS.local.md`, route genuinely personal or environment-specific discoveries there instead.

## Analysis Process

1. **Review Session History**
   - Examine all files read and modified during this session
   - Identify patterns discovered while working on tasks
   - Note architectural insights gained from exploring the codebase

2. **Extract Strategic Knowledge**
   - Filter out tactical details (bug fixes, specific implementations)
   - Focus on reusable patterns and project structure
   - Identify conventions and architectural decisions

3. **Categorize Findings**
   - Project architecture and structure
   - Data flow patterns
   - External service integrations
   - Project-specific conventions
   - Key dependencies and their purposes
   - Configuration patterns
   - Testing strategies
   - Build and deployment processes
   - Operational knowledge (debugging, DevOps)

## Destinations

This skill writes to one of two files in the project root:

- **`AGENTS.md`** (project memory, committed, team-shared) — the default destination. Use for architecture, conventions, integration patterns, and any other knowledge useful to the whole team.
- **`AGENTS.local.md`** (local memory, gitignored personal overrides) — used only when **both** conditions hold:
  1. `AGENTS.local.md` already exists in the project (the project has opted into the three-tier memory convention). Note: opencode does not auto-load this file — the project's AGENTS.md should reference it via an instruction, or `instructions` in opencode.json should include it.
  2. The discovery describes per-developer / per-checkout state — not just *mentions* something personal, but the knowledge itself is meaningful only to the current developer on this machine. Examples: a tool-loading workaround that depends on this developer's interpreter / runtime setup, a personal alias, a per-checkout env override.

  **Counter-example:** *"We keep credentials in `~/.aws/credentials`"* mentions a user-home path but describes a team-wide convention — the path is illustrative, not per-developer state. Such notes belong in project AGENTS.md. When in doubt about whether a discovery is genuinely personal, default to project AGENTS.md.

This skill never writes to the user's global `~/.config/opencode/AGENTS.md` (user memory) — only reads it to avoid duplicating cross-project knowledge.

**Default for ambiguous cases: project AGENTS.md.** Leaking personal config into a committed file is a loud error that reviewers catch quickly; hiding project-wide knowledge in a gitignored personal file is a silent error that rots over time.

## What Qualifies

**INCLUDE** - Strategic discoveries from this session:
- Architectural patterns uncovered while working
- Project structure insights gained from navigation
- Conventions noticed across multiple files
- Integration patterns discovered
- Configuration approaches identified
- Testing strategies observed
- Build/deployment processes encountered
- Performance optimizations found
- Security implementations discovered
- Operational knowledge:
  - Database locations and connection details per environment
  - Useful queries discovered during debugging
  - Testing procedures and verification steps
  - Deployment workflows and commands
  - Log locations and monitoring endpoints
  - Environment-specific quirks and gotchas

**EXCLUDE** - Session-specific tactical work:
- The specific bug we fixed
- The particular feature we implemented
- Temporary workarounds we used
- One-off code changes
- TODO items we encountered
- Historical context about changes

## Decision Criteria

Ask yourself for each discovery:
- "Will this help understand the project in 6 months?"
- "Is this a pattern that appears multiple times?"
- "Does this represent a project-wide convention?"
- "Would knowing this speed up future development?"
- "Would this save debugging time in the future?" (for operational knowledge)

## Workflow

### 1. Check for Existing Memory-Placement Guidance
Before applying the routing rules below, scan the project's root `AGENTS.md` (and `CLAUDE.md` if present), any `.opencode/rules/*.md` files, and the user's global `~/.config/opencode/AGENTS.md` for documented memory-placement guidance — for example, a placement decision tree, an instruction to use a project-specific triage command, or specific destinations beyond `AGENTS.md` / `AGENTS.local.md`. If such guidance exists, defer to it: follow the documented workflow or place each discovery according to its rules instead of using this skill's defaults. The remaining steps apply only when no such guidance is found.

### 2. Check Existing Memory Content
Read the current content of project `AGENTS.md`, `AGENTS.local.md` (if present), and the user's global `~/.config/opencode/AGENTS.md` to avoid duplication — including cross-project entries already captured in user memory.

### 3. Early Exit if Nothing Found
If no new strategic knowledge was discovered during this session:
- Report "no new strategic knowledge to capture"
- Do NOT ask the user anything
- End the skill execution

### 4. Classify Each Discovery
For each discovery, determine its destination per the [Destinations](#destinations) rules: default to project AGENTS.md, and route to `AGENTS.local.md` only when both file-exists and personal-content criteria are met (and the counter-example caveat doesn't apply).

### 5. New Knowledge to Add
Present discovered knowledge formatted for the chosen destination, tagging each block with its inferred file:
```markdown
## [Section Name] → project AGENTS.md
- Discovery 1
- Discovery 2
```

### 6. User Confirmation via the Question Tool

**CRITICAL**: Use the question tool for granular selection of what to save.

Build options dynamically based on discoveries:
- First option: "All knowledge" - save everything to its inferred destination
- Last option: "None" - skip saving entirely
- Middle options: Individual knowledge items (up to 2-3 most significant), each labelled with its inferred destination
- User can always answer with a custom selection in their own words

Example with 3 discoveries (2 project, 1 personal):
```yaml
question: "Which knowledge should I save?"
options:
  - label: "All (3 items)"
    description: "Save all discovered patterns to their inferred destinations"
  - label: "Service discovery pattern → project AGENTS.md"
    description: "Project-wide convention for how modules find each other"
  - label: "Local toolchain variant → AGENTS.local.md"
    description: "Per-checkout build runner override (only relevant on this machine)"
  - label: "None"
    description: "Skip saving, nothing worth keeping"
```

Example with 1 discovery:
```yaml
question: "Save this knowledge?"
options:
  - label: "Yes → project AGENTS.md"
    description: "Save: [brief description of the discovery]"
  - label: "No"
    description: "Skip saving"
```

After user selection:
- "All" -> save everything to its inferred destination
- "None" -> end without saving
- Specific item -> save only that item, to the inferred destination shown in the label
- Custom answer -> user names **which discoveries** to save (comma-separated item names). Destinations follow the labels shown — a custom answer does NOT redirect a destination to an arbitrary path. To override a routing decision, the user should decline the auto-classification, edit the destination file manually, or re-invoke the skill with explicit instructions.

## Important Guidelines
- Only capture genuinely new discoveries from this session
- Don't duplicate existing project AGENTS.md, `AGENTS.local.md`, or user-global AGENTS.md content
- Focus on patterns observed, not specific code written
- Keep descriptions concise and actionable
- MUST use the question tool for confirmation (not plain text questions)
- If no knowledge found, exit early without asking
- **Defer to project- or user-level memory-placement guidance discovered in step 1** — do not override existing conventions with this skill's defaults
