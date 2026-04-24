# Plugin status + known limitations

## Verified end-to-end (2026-04-24)

| Check | Result |
|---|---|
| Plugin directory scaffold | ✅ 36 files in place |
| Main skill v2.0.0 | ✅ 401 lines, CSO-compliant description |
| References (5 files) | ✅ 3,015 lines total |
| Templates (12 files) | ✅ All copied + parametrized from LAMP1 |
| Sub-agents (3 personas) | ✅ Expert smoke-tested against Llama-3.1-8B scenario |
| Slash commands (5) | ✅ All 5 command docs present |
| Hook `post-deploy-audit.json` | ✅ Enabled (advisory-only) |
| `.codex/INSTALL.md` + bootstrap | ✅ Codex integration live |
| `.opencode/INSTALL.md` | ✅ Placeholder for OpenCode |
| v1.0.0 redirect header | ✅ Old skill at `~/.claude/skills/runpod-serverless-deploy/SKILL.md` now points here |
| GitHub repo | ✅ https://github.com/james47kjv/runpod-serverless-skills (public) |
| Registered in `installed_plugins.json` | ✅ `runpod-serverless@local` entry |
| `~/.codex/agent-rules.md` bootstrap line | ✅ Appended |
| Sub-agent smoke test | ✅ Expert persona read all 3 required files, produced valid Llama-3.1-8B deploy plan |

## Known limitations / deferred

### Graphiti memory — unavailable

The `auto-episode-triggers` skill (installed at
`~/.claude/skills/auto-episode-triggers/`) is designed to write episodes
to a Graphiti instance on significant events. **Graphiti is currently
not working on this machine** (2026-04-24). Consequence:

- Successful RunPod deploys will NOT auto-write episodes capturing
  image tag, canary pass rate, latency p50, defects found.
- The "self-improvement" loop described in the original plan (build a
  knowledge base over time) is NOT active.

If/when Graphiti comes back online, the `runpod-serverless-expert`
sub-agent's "On completion" section (persona §Report format) proposes
writing an episode after every successful deploy. Nothing in this
plugin calls the Graphiti API directly, so nothing will crash — the
memory layer is simply advisory.

### Doc-drift monitoring — manual

The plugin's `REFERENCES/` are verbatim copies of the canonical LAMP1
docs at `C:/Users/innas/finance/docs/`. If the canonical docs evolve,
this plugin goes stale until someone re-runs the copy. No automated
drift check is wired today. Add a nightly cron (see `schedule` skill)
to `diff` them and warn on mismatch.
