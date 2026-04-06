# MASTER PLAN: {Project Name}

## Vision
<!-- One paragraph: what we're building and WHY. Agents read this to make
     judgment calls when items are ambiguous. Focus on the user/customer
     problem, not just the technical solution. -->

{Replace with your vision}

## Tech Stack & Constraints
<!-- Language, framework, key deps, patterns to follow -->
- Language: {e.g., TypeScript, Go, Python}
- Framework: {e.g., Next.js, Hono, FastAPI}
- Key dependencies: {list}
- Existing patterns to follow: {link to files or describe}
- Max lines per item: 500

## Items
<!-- 
  Status markers — the loop reads these every iteration:
    [ ]       = todo (processed in order)
    [>]       = do this next (overrides order)
    [x]       = done
    [skip]    = skip this item
    [blocked] = blocked, move on
    [wip]     = in progress (set by the loop, not you)
  
  You can add, remove, reorder items at ANY time.
  The loop re-reads this file every iteration.
  
  For one-shot course corrections, drop a STEER.md in the repo root instead.
  
  To group items into a single PR, add a milestone comment:
  <!-- milestone: v1-api -->
-->

### [ ] 1. {Item title}
- **Description**: {What to build — enough detail for a senior engineer}
- **Scope**: `{dir1}/`, `{dir2}/`
- **Forbidden**: `.env`, `{other dirs/files}`
- **Success criteria**:
  - [ ] {Testable condition — a command to run, expected output}
  - [ ] {Another testable condition}
- **Dependencies**: None

### [ ] 2. {Item title}
- **Description**: {What to build}
- **Scope**: `{dir}/`
- **Forbidden**: `.env`
- **Success criteria**:
  - [ ] {Testable condition}
- **Dependencies**: Item 1

### [ ] 3. {Item title}
- **Description**: {What to build}
- **Scope**: `{dir}/`
- **Forbidden**: `.env`
- **Success criteria**:
  - [ ] {Testable condition}
- **Dependencies**: Item 1, Item 2

<!-- Add more items as you iterate. This seeds direction, not the full scope. -->

## Global Guardrails
<!-- Rules that apply to ALL items -->
- Never modify: `.env`, `.env.*`, `docker-compose.yml`
- Max files changed per iteration: 10
- Follow existing code style and patterns
- If unsure about an architectural decision → STOP and ask human
- No new dependencies without human approval

## Review Criteria
<!-- What cross-model review (Claude + Codex) should check -->
- No scope drift beyond item's allowed dirs
- All tests pass
- No new dependencies added without approval
- Follows existing code style
- No security vulnerabilities (OWASP top 10)
- No hardcoded secrets or credentials

## Evolution Rules
<!-- How the loop handles success and failure -->
- On test failure: retry with error context (max 3 attempts)
- On scope drift: STOP, notify human
- On ambiguous requirement: STOP, ask human
- On success: mark `[x]`, commit with descriptive message, move to next item
- Log all failures + fixes in EVOLUTION_LOG.md
- After 3 consecutive failures on same item: mark `[blocked]`, notify human, move on
