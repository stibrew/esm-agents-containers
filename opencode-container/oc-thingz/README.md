# oc-thingz — an AI-team template for opencode

A deployable [opencode](https://opencode.ai) template that gives a small team a production-grade, multi-agent engineering workflow on **whatever models they can afford** — open-weight models by default, with optional drop-in slots for stronger commercial models where a few licenses exist.

It is a port of [umputun/cc-thingz](https://github.com/umputun/cc-thingz) (a Claude Code plugin collection, MIT) to opencode, restructured so that **model routing is a config decision, not a workflow decision**: the same agents, skills, and pipeline run unchanged whether the team is on a self-hosted vLLM box, OpenRouter's cheapest open models, or a mix with one or two Anthropic seats.

## Why

Quality engineering labor is expensive. This template's premise: a small team (or a single operator) plus a disciplined AI pipeline — plans reviewed before execution, execution done task-by-task by isolated agents, results reviewed by multiple independent specialists and a cross-model adversary — produces reviewable, tested, merge-ready branches with the human kept at the few gates that matter.

## 5-minute start

```bash
# 1. get opencode
curl -fsSL https://opencode.ai/install | bash

# 2. clone this template as your project scaffold (or copy .opencode/, opencode.json, AGENTS.md into an existing repo)
git clone <this-repo> myproject && cd myproject

# 3. authenticate a provider (default config uses OpenRouter)
opencode auth login        # pick OpenRouter, paste API key
# ...or export OPENROUTER_API_KEY

# 4. start
opencode
```

Then, inside opencode:

```
/plan-make add a hello endpoint to the API
```

…answer its questions, let the `plan-review` agent check the plan, then run `/plan-exec` and watch the pipeline implement, review, and finalize a branch.

## The core loop

```
brainstorm (skill)      collaborative design dialogue
   ↓
/plan-make              structured plan file in docs/plans/  ← HUMAN GATE: approve the plan
   ↓
@plan-review (agent)    read-only plan audit, APPROVE / NEEDS REVISION verdict
   ↓
/plan-exec              autonomous execution:
                          task loop     — one task-executor subagent per plan task
                          review 1      — 5 parallel specialist reviewers + fixer (loop)
                          review 2      — code-smells reviewer + fixer
                          review 3      — cross-model ADVERSARY review loop   ← independent model family
                          review 4      — critical-only re-check
                          finalize      — rebase, squash, verify
   ↓
human review of the finalized branch                          ← HUMAN GATE: merge
```

## Components

| Kind | Name | What it does |
|---|---|---|
| command | `/plan-make` | create a structured plan file with interactive context gathering |
| command | `/plan-exec` | run the exec pipeline on a plan |
| agent | `plan-review` | read-only plan quality audit (reasoning tier) |
| agent | `task-executor` | implements exactly one plan task, tests, commits |
| agent | `reviewer-{quality, implementation, testing, simplification, documentation, smells}` | read-only review specialists |
| agent | `adversary` | independent second opinion on a different model family |
| agent | `fixer` | verifies findings, fixes confirmed ones, commits |
| agent | `finalizer` | rebase / squash / verify before merge |
| agent | `investigator` | generic read-only deep-analysis worker |
| skill | `brainstorm` | idea → design dialogue |
| skill | `exec` | the 13-step orchestration playbook behind /plan-exec |
| skill | `pr` | full PR/issue review flow (gh-based, subagent deep-dive) |
| skill | `git-review` | annotate-a-diff review loop with your own editor |
| skill | `writing-style` | no-AI-speak technical communication style |
| skill | `ask-adversary` | cross-model second opinion when stuck |
| skill | `dialectic` | thesis/antithesis parallel analysis of a claim |
| skill | `root-cause-investigator` | 5-why debugging methodology |
| skill | `release-new`, `last-tag` | release cutting + release-delta reporting |
| skill | `learn`, `clarify`, `wrong`, `md-copy`, `txt-copy` | session workflow helpers |

## Model routing

All routing is in **one file**, `opencode.json`:

- `model` — the **worker** tier (implementation, fixing, reviewing; most tokens)
- `small_model` — the **fast** tier (titles, summaries)
- `agent.plan` / `agent.plan-review` — the **reasoning** tier (low volume, high leverage)
- `agent.adversary` — the **adversary** tier (keep on a *different model family* than the workers)

Defaults are hosted open-weight models via OpenRouter. `opencode.anthropic.jsonc` is a fully-commented alternate routing for teams with Anthropic seats — including the recommended hybrid (workers open, adversary Anthropic) for 1–2 licenses. Self-hosted (Ollama/vLLM) recipe: [docs/model-routing.md](docs/model-routing.md).

Nothing in the workflow requires any particular vendor.

## Docs

- [docs/setup.md](docs/setup.md) — install, auth, verifying everything loads
- [docs/model-routing.md](docs/model-routing.md) — tier philosophy, swapping providers, self-hosting
- [docs/team-playbook.md](docs/team-playbook.md) — how a team runs this: roles, gates, cost control
- [docs/porting-notes.md](docs/porting-notes.md) — every deviation from upstream cc-thingz, with rationale
- [docs/evaluation.md](docs/evaluation.md) — real-world evaluation of the workflow on a self-hosted open model, with failure modes and the conductor pattern for slow models
- [.opencode/rules/README.md](.opencode/rules/README.md) — injecting project-specific rules into the workflows

## Customizing

- **A role behaves wrong** → edit its agent file in `.opencode/agents/` and commit; the template repo is the distribution unit.
- **Project-specific conventions** → add `.opencode/rules/planning-rules.md` / `brainstorm-rules.md` (see rules README).
- **Exec prompt templates** → override per-project under `.opencode/exec-plan/` (resolved by `resolve-file.sh`).
- **Pipeline knobs** (retries, iteration caps) → the Configuration table at the top of `.opencode/skills/exec/SKILL.md`.

## Tests

```bash
for t in tests/test-*.sh; do bash "$t"; done
python3 .opencode/skills/git-review/scripts/git-review.py --test
```

## Credits and license

Ported from [umputun/cc-thingz](https://github.com/umputun/cc-thingz) (MIT), which ships the original Claude Code plugins this template is based on. The upstream source is vendored untouched under `inspiration/` for reference. This template is MIT as well.
