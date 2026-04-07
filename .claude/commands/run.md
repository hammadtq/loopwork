---
description: Launch the loopwork orchestration loop
argument-hint: "review PR owner/repo#17" or describe what to build, or --status/--stop/--tail
allowed-tools: [Bash, Read, Write, Glob, Grep]
---

# Loopwork /run Command

You are launching the loopwork orchestration loop. Loopwork runs Claude Code + Codex autonomously to build features, review PRs, and ship code.

## Setup

- **LOOPWORK_DIR**: must be set in the environment to the absolute path of the loopwork checkout. If `$LOOPWORK_DIR` is unset, fall back to these candidates in order and use the first that exists:
  1. `$HOME/loopwork`
  2. `$HOME/src/loopwork`
  3. `$HOME/go/src/github.com/hammadtq/attach-dev/loopwork`
  If none exist, STOP and tell the user: `LOOPWORK_DIR is not set and loopwork was not found in any default location. Run: export LOOPWORK_DIR=/path/to/loopwork`
- **WORKING_DIR**: The current working directory (`$PWD`) — this is the repo being operated on
- **DAEMON**: `bash "$LOOPWORK_DIR/lib/daemon.sh"`

When you run any of the bash snippets below, always quote `"$LOOPWORK_DIR"` so paths with spaces work.

## Step 1: Parse arguments

The user input is: `$ARGUMENTS`

Determine the intent:

### If `--status`:
Run: `bash "$LOOPWORK_DIR/lib/daemon.sh" "$PWD" status`
Show the output to the user. Done.

### If `--stop`:
Run: `bash "$LOOPWORK_DIR/lib/daemon.sh" "$PWD" stop`
Show the output to the user. Done.

### If `--tail`:
Run: `timeout 30 bash "$LOOPWORK_DIR/lib/daemon.sh" "$PWD" tail` (or use the portable run_with_timeout if `timeout` is not available).
Show the output. Done.

### If it contains a PR reference (pattern: `owner/repo#N` or `#N`):
This is a **review request**. Go to Step 2A.

### If it contains a description of features, tasks, or a brainstorm:
This is a **build request**. Go to Step 2B.

### If empty and MASTER_PLAN.md exists in the working directory:
Show the user a summary of the existing plan (run `bash "$LOOPWORK_DIR/lib/parse-plan.sh" "$PWD/MASTER_PLAN.md" count`). Ask: "Launch the loop with this plan?"
If yes, go to Step 3.

### If empty and no MASTER_PLAN.md:
Ask the user: "What would you like to do? Options:
1. Review a PR (provide the PR reference like `owner/repo#17`)
2. Build features (describe what you want to build)
3. Paste a brainstorm or master plan"

## Step 2A: Generate review plan

Extract the PR reference from the user input. Generate a MASTER_PLAN.md:

```markdown
# MASTER PLAN: PR Review

## Items

### [>] 1. Review PR {pr_ref}
- **Description**: Review and fix {pr_ref}
- **Success criteria**:
  - [ ] No critical issues in Claude + Codex reviews
  - [ ] All fixes pushed to PR branch

## Global Guardrails
- Never auto-merge

## Evolution Rules
- On failure: retry (max 3)
- On success: mark [x], move on
```

Check if the working directory is a git repo. If not, set one up:
```bash
git init && git add -A && git commit -m "init"
```

Write the MASTER_PLAN.md to the working directory. Then go to Step 3.

## Step 2B: Generate build plan

You are a product architect. Generate a MASTER_PLAN.md from the user's description following these rules:

### Vision section
- ONE paragraph capturing what we are building and WHY
- Focus on the user/customer problem, not just the technical solution

### Items (3-5 foundational items)
- Order by dependency — foundational items first
- Each item MUST have:
  - **Description**: Enough detail for a senior engineer to implement without questions
  - **Scope**: Which directories/files this item is ALLOWED to touch
  - **Forbidden**: Files this item must NOT touch (at minimum: `.env`, credentials)
  - **Success criteria**: Testable conditions — commands to run, expected outputs
  - **Dependencies**: Which other items must be done first
- Keep items small (< 500 lines changed each)
- If a feature is big, split into multiple items

### Other sections
- **Tech Stack & Constraints**: Infer from the repo (check package.json, go.mod, requirements.txt, Cargo.toml, etc.)
- **Global Guardrails**: Never modify `.env`, max 10 files per iteration
- **Review Criteria**: No bugs, tests pass, no security issues
- **Evolution Rules**: retry max 3, stop on scope drift, log failures

Use this exact format:
```markdown
# MASTER PLAN: {Project Name}

## Vision
{one paragraph}

## Tech Stack & Constraints
- {language/framework}
- Max lines per item: 500

## Items

### [ ] 1. {Title}
- **Description**: {what to build}
- **Scope**: `{dir1}/`, `{dir2}/`
- **Forbidden**: `.env`
- **Success criteria**:
  - [ ] {testable condition}
- **Dependencies**: None

## Global Guardrails
- Never modify: `.env`, `.env.*`
- Max files per iteration: 10
- If unsure about architecture: STOP and ask human

## Review Criteria
- No scope drift
- All tests pass
- No security vulnerabilities

## Evolution Rules
- On failure: retry (max 3)
- On scope drift: STOP
- On success: mark [x], move on
```

Write the MASTER_PLAN.md to the working directory and proceed straight to Step 3 — do not ask for confirmation. The user invoked `/run` precisely so they can walk away. If you have genuine architectural ambiguity, STOP and ask; otherwise launch.

## Step 3: Launch the loop

Run the daemon to start the loop in the background:
```bash
bash "$LOOPWORK_DIR/lib/daemon.sh" "$PWD" start
```

Wait 3 seconds, then show initial progress:
```bash
tail -20 .workflow/loop.log 2>/dev/null
```

Tell the user:
- "The loop is running in the background (survives terminal disconnects)."
- "Use `/run --status` to check progress."
- "Use `/run --tail` to watch live output."
- "Use `/run --stop` to halt the loop."
