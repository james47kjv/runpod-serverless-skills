# Codex install — runpod-serverless plugin

Codex does not have the `Skill` tool or `Task` sub-agent primitives
that Claude Code does. The plugin's skills are still usable from Codex
— just via `cat`/`Read` instead of `Skill`.

Codex's authoritative session-start file is `~/.codex/AGENTS.md` (NOT
`~/.codex/agent-rules.md`; that one is a Cursor-style rules file).

## One-time install

```bash
# 1. Link the plugin into Codex's search path.
#    NOTE: CLAUDE_PLUGIN_ROOT is only defined inside Claude Code. For a
#    manual install, use the actual filesystem path:
ln -s "$HOME/.claude/plugins/local/runpod-serverless" "$HOME/.codex/runpod-serverless"

# 2. Append the plugin's Codex section to ~/.codex/AGENTS.md.
#    This is where Codex ACTUALLY reads session-start policy.
cat >> ~/.codex/AGENTS.md <<'EOF'

## RunPod Serverless plugin

<EXTREMELY_IMPORTANT>
You have access to the `runpod-serverless` plugin at `~/.codex/runpod-serverless/`.

On any task matching "deploy to RunPod Serverless", "create a serverless endpoint",
"ship this model/harness as a live API", "audit the endpoint", "run the canaries",
"my RunPod worker is stuck", or any repo with `deploy/runpod/*.json` specs —
FIRST read the relevant skill:

- Deploy:  `cat ~/.codex/runpod-serverless/skills/runpod-serverless-deploy/SKILL.md`
- Debug:   `cat ~/.codex/runpod-serverless/skills/runpod-serverless-debug/SKILL.md`
- Red team: `cat ~/.codex/runpod-serverless/skills/runpod-red-team/SKILL.md`

Then follow its CHECKLIST. Full canonical references in
`~/.codex/runpod-serverless/skills/runpod-serverless-deploy/REFERENCES/`.
Templates (13 files) in the same skill's `TEMPLATES/`.

For Claude primitives Codex doesn't have, see the cross-agent mapping
in `~/.codex/runpod-serverless/.codex/runpod-codex-bootstrap.md`.
</EXTREMELY_IMPORTANT>
EOF
```

## Verification

Open a fresh Codex session and ask: "Do you have the runpod-serverless
skill available?" Codex should cite the AGENTS.md block and offer to
read the specific skill file for your task.

## What Codex gets

- Full skill content (`cat skills/<name>/SKILL.md`)
- All 5 REFERENCES (setup guide, harness guidebook, red-team handover,
  anti-cheating contract, pitfalls-22)
- All 13 templates
- The 3 sub-agent persona docs (treated as instructions — Codex reads
  them and executes the work itself; no `Task` tool)
- The 5 slash-command recipes (treated as workflow scripts)

## What Codex does NOT get

- `Skill` tool — use `Read` on `SKILL.md` directly
- `Task(subagent_type=...)` — read the persona markdown and execute
  yourself
- `/rp-*` slash shortcuts — read `commands/rp-*.md` and execute steps
  via Bash
- `hooks/hooks.json` — no `PostToolUse` runtime in Codex; run the
  drift-audit manually after every `saveEndpoint` mutation
