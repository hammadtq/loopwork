# Loopwork

A Ralph-loop orchestrator for autonomous multi-agent coding workflows. Uses Claude Code + Codex for building, reviewing, and shipping code with human-in-the-loop steering.

## How it works

```
/run "build X" or "review PR Y" → MASTER_PLAN.md generated →
Ralph loop picks up items → Claude Code builds (worktree) →
Codex reviews → PR created → you approve on phone →
loop continues to next item
```

## Quick start

Open Claude Code in any repo and use the `/run` command:

```
/run review PR attach-dev/attach-guard#17
/run build JWT auth with refresh tokens
/run --status
/run --tail
/run --stop
```

The `/run` command:
1. Detects your intent (review PR, build features, or use existing plan)
2. Generates a `MASTER_PLAN.md` automatically
3. Launches the loop as a **background process** (survives terminal disconnects)
4. Shows you how to monitor progress

### Examples

**Review a PR:**
```
/run review PR owner/repo#17
```

**Build features** (describe what you want):
```
/run add user authentication with OAuth2 and session management
```

**Use an existing plan** (if MASTER_PLAN.md exists):
```
/run
```

**Monitor a running loop:**
```
/run --status    # Plan progress + recent log
/run --tail      # Live log output
/run --stop      # Stop the loop
```

### Manual usage

You can also run the loop directly:

```bash
~/go/src/github.com/hammadtq/attach-dev/loopwork/run.sh /path/to/repo --auto    # Headless
~/go/src/github.com/hammadtq/attach-dev/loopwork/run.sh /path/to/repo --status  # Status
~/go/src/github.com/hammadtq/attach-dev/loopwork/lib/daemon.sh /path/to/repo start  # Background
```

### Steer mid-flight

**While running:**
- Edit `MASTER_PLAN.md` directly — add/remove/reorder items
- Mark items `[>]` (do next), `[skip]`, `[blocked]`

**Away from keyboard:**
- Drop a `STEER.md` in the repo root with free-text instructions

## Item types

### Build items (default)
Standard implementation tasks. The loop runs Claude Code to build, then reviews.

### Review items (auto-detected)
Any item with a PR ref (`owner/repo#N`) in its description triggers the review-fix loop:

```markdown
### [ ] 4. Review PR attach-dev/attach-guard#17
- **Description**: Review and fix attach-dev/attach-guard#17
```

The loop will:
1. Checkout the PR branch
2. Run Claude + Codex reviews **in parallel**
3. Auto-fix actionable issues (critical + warnings)
4. Re-review until clean (max 5 iterations)
5. Push fixes and post summary to PR
6. Move to the next item — no waiting

## Plan format

Items in `MASTER_PLAN.md` use status markers:

| Marker | Meaning |
|--------|---------|
| `[ ]` | Todo (processed in order) |
| `[>]` | Do this next (overrides order) |
| `[x]` | Done |
| `[skip]` | Skip |
| `[blocked]` | Blocked — needs human input |
| `[wip]` | In progress (set by the loop) |

## Prerequisites

- [Claude Code CLI](https://claude.ai/code) (required)
- [GitHub CLI](https://cli.github.com/) (for PR creation)
- [OpenAI Codex CLI](https://github.com/openai/codex) (for cross-model review, optional)
- `git`, `python3`, `bash`

## Scope guard

The scope guard hook prevents agents from modifying files outside the current item's allowed scope. To enable it, add to your project's `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Edit|Write",
      "hooks": [{
        "type": "command",
        "command": "/path/to/loopwork/hooks/scope-guard.sh"
      }]
    }]
  }
}
```

## File structure

```
loopwork/
├── .claude/commands/
│   └── run.md              # /run slash command for Claude Code
├── META_PROMPT.md          # Paste into ChatGPT with your brainstorm
├── MASTER_PLAN_TEMPLATE.md # Template → becomes MASTER_PLAN.md
├── run.sh                  # Main entry point (Ralph loop)
├── lib/
│   ├── daemon.sh           # Background process lifecycle (start/stop/tail/status)
│   ├── parse-plan.sh       # Parse MASTER_PLAN.md
│   ├── scope-check.sh      # Verify changes are in scope
│   ├── review.sh           # Cross-model review (Claude + Codex)
│   ├── review-fix.sh       # Review-fix-resubmit loop for PRs
│   ├── pr.sh               # Create PR + notify
│   ├── worktree.sh         # Git worktree management
│   ├── steer.sh            # STEER.md hotfile handling
│   └── evolve.sh           # Evolution log management
├── hooks/
│   └── scope-guard.sh      # Claude Code PreToolUse hook
└── templates/
    └── EVOLUTION_LOG.md    # Template for iteration log
```

## Roadmap

- [x] Slice 1: Meta-prompt + plan template
- [x] Slice 2: Ralph loop (bash, interactive + headless)
- [x] Slice 3: Non-blocking PR + cross-model review
- [x] Slice 4: Scope drift hook
- [x] Slice 5: `/run` slash command + background daemon
- [x] Slice 6: Review-fix loop (fix all actionable issues, not just critical)
- [ ] Slice 7: Telegram integration (notify on completion/failure)
- [ ] Slice 8: Self-evolution (AutoAgent pattern)
