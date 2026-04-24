# runpod-serverless — Cross-Agent Deployment Plugin

Production-grade RunPod Serverless deployment knowledge packaged as a
reusable Claude Code plugin with Codex + OpenCode bootstrap shims.

Distilled from the 2026-04-23 LAMP1 finance-agent rebuild that shipped a
FastAPI + Qwen3.5 NVFP4 vLLM inference stack to RunPod Serverless with:

- Integrity-gating anti-cheating contract
- Propose-review-judge agent runtime (6 candidates, 5 verifiers, arbiter, critic)
- `X-Lamp-Debug-Token` defense-in-depth on the debug-trace route
- Bounded `_WORKSPACE_LOCKS` with LRU eviction
- 17-marker leak scrubber
- Scaler-cascade clean-drain procedure
- 22 learned pitfalls, each with symptom and fix

## What's in the box

- **3 skills** — deploy, debug-triage, red-team
- **3 sub-agents** — `runpod-serverless-expert`, `runpod-red-team-auditor`, `runpod-incident-responder`
- **5 slash commands** — `/rp-deploy`, `/rp-canary`, `/rp-drain`, `/rp-warm`, `/rp-audit`
- **12 templates** — `Dockerfile`, `start.sh`, spec JSON, GHA workflows, `audit_build_context.py`, `deploy_endpoint.py`, canary + grader scripts, integrity-assertion snippet
- **1 hook** — auto-audit after any `saveEndpoint` mutation (enabled by default; see below)
- **5 reference documents** — the full canonical corpus (2,544 lines across 4 files + a 22-pitfall catalog)
- **Cross-agent bootstrap** — `.codex/` and `.opencode/` shims mirroring the Superpowers pattern

## Install

### Claude Code — local install (this machine)

```bash
# Already installed if this file exists at
#   ~/.claude/plugins/local/runpod-serverless/
# Verify:
/plugin list | grep runpod-serverless
# If it does not show up, register:
/plugin install --local ~/.claude/plugins/local/runpod-serverless
```

### Claude Code — marketplace install (other machines, after `gh repo create`)

```bash
/plugin marketplace add james47kjv/runpod-serverless-skills
/plugin install runpod-serverless
```

### Codex

See `.codex/INSTALL.md`. One-liner:

```bash
ln -s ~/.claude/plugins/local/runpod-serverless ~/.codex/runpod-serverless
echo 'include ~/.codex/runpod-serverless/.codex/runpod-codex-bootstrap.md' \
  >> ~/.codex/agent-rules.md
```

### Cursor

Cursor does not have a skill primitive. Add this line to your repo's
`AGENTS.md` to tell Cursor agents the plugin exists and where to read
its skills:

```markdown
## RunPod deploys

When deploying to RunPod Serverless, read
`~/.claude/plugins/local/runpod-serverless/skills/runpod-serverless-deploy/SKILL.md`
and follow it.
```

## Quick usage

```bash
# Full deploy wizard
/rp-deploy immutable-20260423-174553-5f1821f --env staging

# Run both canaries (public-50 + synthetic-50) against staging
/rp-canary staging

# Drain both endpoints to workersMax=0
/rp-drain all

# Warm an endpoint before a Vals.ai submission
/rp-warm production
```

Or delegate to a sub-agent from any Claude Code session:

```
Task(subagent_type="runpod-serverless-expert",
     prompt="Scaffold a RunPod Serverless deploy for my FastAPI + Llama 3.1-8B service.")
```

## The non-negotiable contract

Every deploy using this plugin MUST satisfy:

1. **Image-based only.** No `networkVolumeId`, no `startScriptPath`.
2. **Immutable image tags.** `immutable-<UTC>-<sha>` format. Never overwrite.
3. **Model via `modelName` + `flashboot: true`**. Weights NOT baked in.
4. **Staging + production specs** differing only in workers + env label.
5. **Drift audit** before every production deploy.
6. **No silent failures in `start.sh`.** Structured JSON at every boot stage.
7. **`GHCR_PAT`, not `GITHUB_TOKEN`**, for GHCR login in CI.
8. **Integrity gating off in production.** `LAMP_OFFLINE_FIXTURES` and
   `LAMP_DETERMINISTIC_OVERRIDES` must be unset. Boot assertion enforces.
9. **App-layer auth on debug routes.** Gateway `Authorization` + app-layer
   `X-Lamp-Debug-Token` both required. Defense in depth.

See `skills/runpod-serverless-deploy/REFERENCES/anti-cheating-contract.md`
for the full contract.

## Hook behavior (enabled)

`hooks/post-deploy-audit.json` is **enabled by default**. It runs
`audit_digest.py` after any `saveEndpoint` GraphQL mutation detected in
the session, flagging drift between the live template image and the
release manifest. Read-only; never deploys. Disable by removing the
file or setting `"enabled": false` inside it.

## Canonical LAMP1 reference

This plugin's `REFERENCES/` contains verbatim copies of the LAMP1 canon
as of 2026-04-23:

- `setup-guide-full.md` — 1,022-line serverless setup guide
- `harness-guidebook.md` — 1,013-line harness architecture guide
- `red-team-handover.md` — 505-line red-team contract
- `anti-cheating-contract.md` — §11.9 integrity-gating excerpt
- `pitfalls-22.md` — consolidated 22-pitfall catalog

The source of truth is `github.com/james47kjv/finance/docs/`. This
plugin is a snapshot; run `scripts/diff-references.sh` (future) to
detect drift.

## License

MIT. Use it. Fork it. Ship to RunPod.
