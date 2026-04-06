# Loopwork

A Ralph-loop orchestrator for autonomous multi-agent coding workflows. Uses Claude Code + Codex for building, reviewing, and shipping code with human-in-the-loop steering.

## How it works

```
You brainstorm (ChatGPT) → MASTER_PLAN.md → Ralph loop picks up items →
Claude Code builds (worktree) → Codex reviews → PR created → you approve on phone →
loop continues to next item
```

## Quick start

Open a Claude Code instance in any repo and ask it to run loopwork. All commands below are run from inside Claude Code (via the Bash tool), not in a raw terminal.

### Option A: Review a PR in another repo

From a Claude Code session, run this script:

```bash
#!/bin/bash
set -e

rm -rf /tmp/loopwork-review
mkdir -p /tmp/loopwork-review
cd /tmp/loopwork-review

cat > MASTER_PLAN.md << 'EOF'
# MASTER PLAN: my-project

## Items

### [>] 1. Review PR owner/repo#17
- **Description**: Review and fix owner/repo#17
- **Success criteria**:
  - [ ] No critical issues in Claude + Codex reviews
  - [ ] All fixes pushed to PR branch

## Global Guardrails
- Never auto-merge

## Evolution Rules
- On failure: retry (max 3)
- On success: mark [x], move on
EOF

git init && git add -A && git commit -m "init"
~/go/src/github.com/hammadtq/attach-dev/loopwork/run.sh . --auto
```

Save this as a script (e.g. `/tmp/review-pr.sh`) and run `bash /tmp/review-pr.sh` from Claude Code. Replace `owner/repo#17` with your actual PR reference.

### Option B: Build features in your own repo

1. Create your plan — copy `META_PROMPT.md` contents into ChatGPT along with your brainstorm. It will produce a `MASTER_PLAN.md`. Drop that into your repo root.

2. From Claude Code, run:

```bash
~/go/src/github.com/hammadtq/attach-dev/loopwork/run.sh /path/to/your/repo          # Interactive
~/go/src/github.com/hammadtq/attach-dev/loopwork/run.sh /path/to/your/repo --auto   # Headless (AFK)
~/go/src/github.com/hammadtq/attach-dev/loopwork/run.sh /path/to/your/repo --status # Check status
```

### Steer mid-flight

**While running:**
- Edit `MASTER_PLAN.md` directly — add/remove/reorder items
- Mark items `[>]` (do next), `[skip]`, `[blocked]`
- In interactive mode, just chat

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
3. Auto-fix critical issues
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
├── META_PROMPT.md          # Paste into ChatGPT with your brainstorm
├── MASTER_PLAN_TEMPLATE.md # Template → becomes MASTER_PLAN.md
├── run.sh                  # Main entry point (Ralph loop)
├── lib/
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
- [ ] Slice 5: Telegram integration (Claude Code Channels)
- [ ] Slice 6: Self-evolution (AutoAgent pattern)
