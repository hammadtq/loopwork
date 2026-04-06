# Meta-Prompt: Generate a MASTER_PLAN.md

> Paste this into ChatGPT along with your brainstorm/idea. It will produce a
> MASTER_PLAN.md that an autonomous Ralph loop agent can execute.

---

You are a product architect helping me turn a rough idea into a structured
execution plan. I'll give you my brainstorm — raw thoughts, goals, constraints,
and vibes. You'll produce a `MASTER_PLAN.md` file that an autonomous AI coding
agent (Claude Code + Codex) will read and execute item by item.

## Rules for generating the plan

### Vision section
- Write ONE paragraph that captures what we're building and WHY
- This is the north star — agents read it to make judgment calls on ambiguous items
- Include the user/customer problem, not just the technical solution

### Tech Stack & Constraints
- List language, framework, key dependencies
- Reference existing patterns in the repo if I mention any
- Set `max_lines_per_item` — default 500 unless I say otherwise
- Include any deployment/infra constraints I mention

### Items
- Start with **3-5 foundational items** — I'll add more as we iterate
- Order by dependency — foundational items first (setup, config, data models before API endpoints before UI)
- Each item MUST have:
  - **Description**: What to build, in enough detail that a senior engineer could implement it without asking questions
  - **Scope**: Which directories/files this item is ALLOWED to touch (be specific: `src/api/`, not `src/`)
  - **Forbidden**: Directories/files this item must NOT touch (at minimum: `.env`, credentials, migrations unless explicitly needed)
  - **Success criteria**: Testable conditions — commands to run, expected outputs, endpoints to hit. The agent uses these to self-verify.
  - **Dependencies**: Which other items must be done first (use item numbers)
- Keep items small enough for one agent iteration (< 500 lines changed)
- If a feature is big, split it into multiple items with clear boundaries
- DO NOT front-load the entire project — seed the direction, leave room for iteration

### Item sizing guidance
- "Set up project structure" = 1 item
- "Build CRUD API for users" = 1 item (if simple) or 3 items (create, read, update+delete) if complex
- "Build full authentication system" = too big — split into: schema, signup endpoint, login endpoint, middleware, tests

### Global Guardrails
- List files/dirs that should NEVER be modified (typically: `.env`, `docker-compose.yml`, `migrations/` unless the item is specifically about migrations)
- Set max files changed per iteration (default: 10)
- Include any code style rules I mention
- Default rule: "If unsure about an architectural decision → STOP and ask"

### Review Criteria
- What the cross-model review (Claude + Codex) should check for
- Include project-specific concerns (e.g., "no raw SQL queries", "all endpoints must have auth middleware")

### Evolution Rules
Keep these defaults unless I override:
- On test failure: retry with error context (max 3 attempts)
- On scope drift: STOP, notify human
- On ambiguous requirement: STOP, ask human
- On success: mark item `[x]`, commit, move to next
- Log all failures + fixes in EVOLUTION_LOG.md

## Format

Use this exact markdown format so the agent can parse it:

```markdown
# MASTER PLAN: {Project Name}

## Vision
{one paragraph}

## Tech Stack & Constraints
- {language/framework}
- {patterns to follow}
- Max lines per item: {N}

## Items
<!-- Status: [ ] todo, [>] do next, [x] done, [skip], [blocked], [wip] -->

### [ ] 1. {Title}
- **Description**: {what to build}
- **Scope**: `{dir1}/`, `{dir2}/`
- **Forbidden**: `{dir3}/`, `{file}`
- **Success criteria**:
  - [ ] {testable condition 1}
  - [ ] {testable condition 2}
- **Dependencies**: None

### [ ] 2. {Title}
...

## Global Guardrails
- Never modify: {list}
- Max files per iteration: {N}
- {additional rules}

## Review Criteria
- {criterion 1}
- {criterion 2}

## Evolution Rules
- On test failure: retry with error context (max 3)
- On scope drift: STOP, notify human
- On ambiguous requirement: STOP, ask human
- On success: mark [x], commit, next item
- Log failures in EVOLUTION_LOG.md
```

## Important
- Do NOT add items I didn't ask for
- Do NOT add "nice to have" features
- Do NOT add error handling, logging, or monitoring items unless I specifically mention them
- When in doubt, make items smaller rather than bigger
- The plan is a LIVING DOCUMENT — I'll add, reorder, and edit items as we go. Don't try to plan everything upfront.

---

## My brainstorm:

{PASTE YOUR RAW BRAINSTORM / IDEA / REQUIREMENTS HERE}
