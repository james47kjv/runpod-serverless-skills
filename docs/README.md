# Plugin internals

This directory holds plugin-level design notes (not user-facing).

## Design principles

1. **One source of truth** — the LAMP1 `finance/docs/` canon is canonical.
   This plugin is a snapshot; never diverge silently.
2. **Skill ≠ sub-agent** — skills = checklists the current agent runs;
   sub-agents = separate agents with their own system context, spawned
   via `Task(subagent_type=...)`.
3. **Templates, not instructions** — every pitfall the skill mentions
   becomes a template file the user can copy. Agents adapt rather than
   hand-write.
4. **100× Claude, baseline Codex** — Claude-only affordances (hooks,
   slash commands, TodoWrite auto-population, sub-agent spawn) ship
   enabled; Codex gets the same skills via a Read-based bootstrap.

## Directory map

```
.claude-plugin/        # manifest + marketplace
skills/                # 3 skills (deploy, debug, red-team)
  runpod-serverless-deploy/
    SKILL.md           # main checklist
    REFERENCES/        # full canonical docs (2544 lines)
    TEMPLATES/         # 12 reusable starter files
  runpod-serverless-debug/
    SKILL.md           # worker-won't-start triage
  runpod-red-team/
    SKILL.md           # canary + audit contract
agents/                # 3 specialized sub-agents
commands/              # 5 slash commands (Claude-only)
hooks/                 # 1 hook (post-deploy audit)
.codex/                # Codex bootstrap shim
.opencode/             # OpenCode bootstrap (placeholder)
docs/                  # this directory
```

## Upgrading from v1.0.0

The previous single-file `~/.claude/skills/runpod-serverless-deploy/SKILL.md`
(203 lines) remains in place with a redirect header pointing here. Any
workflow that references it by name still works — the redirect tells
the agent to prefer this v2.0.0.

## Contribution

1. Edit the canonical docs in `github.com/james47kjv/finance/docs/`
   first.
2. Copy into `REFERENCES/` (manual for now; automation planned).
3. Commit + push to `github.com/james47kjv/runpod-serverless-skills`.
4. Other machines pull via `/plugin marketplace add ...`.
