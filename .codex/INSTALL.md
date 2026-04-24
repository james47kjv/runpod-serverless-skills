# Codex install — runpod-serverless plugin

Codex does not have the `Skill` tool or `Task` sub-agent primitives
that Claude Code does. The plugin's skills are still usable from Codex
— just via `cat`/`Read` instead of `Skill`.

## One-time install

```bash
# 1. Link the plugin into Codex's search path
ln -s ~/.claude/plugins/local/runpod-serverless ~/.codex/runpod-serverless

# 2. Add a bootstrap-include line to Codex's root agent rules
cat >> ~/.codex/agent-rules.md <<'EOF'

## Additional skill: runpod-serverless (v2.0.0)
Read `~/.codex/runpod-serverless/.codex/runpod-codex-bootstrap.md` on every session start. It lists the runpod-serverless skills, sub-agents, and slash commands available, and maps Claude-only primitives to Codex equivalents.
EOF
```

## What Codex gets

- Full skill content (read via `cat ~/.codex/runpod-serverless/skills/<name>/SKILL.md`).
- All 5 REFERENCES (setup guide, harness guidebook, red-team handover, anti-cheating contract, 22-pitfall catalog).
- All 12 templates (ready to `cp` into a new repo).
- The 3 sub-agent persona docs (read as instructions; no `Task` tool exists).
- The 5 slash-command definitions (read as workflow recipes; no
  `/rp-*` shortcut exists).

## What Codex does NOT get

- `Skill` tool — use `Read` on `SKILL.md` directly.
- `Task(subagent_type=...)` — read the sub-agent markdown and execute
  its instructions yourself.
- `commands/*.md` as slash commands — read them as workflow scripts
  and execute their steps via Bash.
- `hooks/*` — no post-tool-use hook runtime. Run `audit_digest.py`
  manually after every `saveEndpoint` mutation.

## Verification

On a fresh Codex session, ask Codex: "Do you have the
runpod-serverless skill available?" and it should respond with the
location and a brief summary (from the bootstrap file).
