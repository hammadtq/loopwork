# Workflow Automation

A Ralph-loop-based orchestrator for autonomous multi-agent coding workflows. Uses Claude Code + Codex for building, reviewing, and shipping code with human-in-the-loop steering.

## How it works

```
You brainstorm (ChatGPT) → MASTER_PLAN.md → Ralph loop picks up items →
Claude Code builds (worktree) → Codex reviews → PR created → you approve on phone →
loop continues to next item
```

## Quick start

### 1. Create your plan

Copy `META_PROMPT.md` contents into ChatGPT along with your brainstorm. It will produce a `MASTER_PLAN.md`. Drop that file into your project repo root.

### 2. Run the loop

```bash
# Interactive — you're at the keyboard, chatting with the agent
./run.sh /path/to/your/repo

# Headless — you're AFK, loop runs autonomously
./run.sh /path/to/your/repo --auto

# Check status
./run.sh /path/to/your/repo --status
```

### 3. Steer mid-flight

**At the terminal:**
- Edit `MASTER_PLAN.md` directly — add/remove/reorder items
- Mark items `[>]` (do next), `[skip]`, `[blocked]`
- In interactive mode, just chat

**Away from keyboard:**
- Drop a `STEER.md` in the repo root with free-text instructions
- (Coming soon) Send Telegram messages to steer via Claude Code Channels

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
├── META_PROMPT.md          # Paste into ChatGPT with your brainstorm
├── MASTER_PLAN_TEMPLATE.md # Template → becomes MASTER_PLAN.md
├── run.sh                  # Main entry point (Ralph loop)
├── lib/
│   ├── parse-plan.sh       # Parse MASTER_PLAN.md
│   ├── scope-check.sh      # Verify changes are in scope
│   ├── review.sh           # Cross-model review (Claude + Codex)
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
- [ ] Slice 5: Telegram integration (Claude Code Channels)
- [ ] Slice 6: Self-evolution (AutoAgent pattern)
