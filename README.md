# runpod-serverless — Cross-Agent Deployment Plugin

Production-grade RunPod Serverless deployment knowledge packaged as a
reusable Claude Code plugin, with a Codex bootstrap shim and a
Cursor-rules integration pattern.

Distilled from the 2026-04-23 LAMP1 finance-agent rebuild that shipped a
FastAPI + Qwen3.5 NVFP4 vLLM inference stack to RunPod Serverless with:

- Integrity-gating anti-cheating contract
- Propose-review-judge agent runtime (6 candidates, 5 verifiers, arbiter, critic)
- `X-Lamp-Debug-Token` defense-in-depth on the debug-trace route
- Bounded `_WORKSPACE_LOCKS` with LRU eviction
- 17-marker leak scrubber (LAMP1's inventory; adapt markers for your app)
- Scaler-cascade clean-drain procedure
- 22 learned pitfalls, each with symptom and fix

## What's in the box

- **3 skills** — deploy, debug-triage, red-team
- **3 sub-agents** — `runpod-serverless-expert`, `runpod-red-team-auditor`, `runpod-incident-responder`
- **5 slash commands** — `/rp-deploy`, `/rp-canary`, `/rp-drain`, `/rp-warm`, `/rp-audit`
- **13 templates** — `Dockerfile`, `start.sh`, spec JSON, GHA workflows, `audit_build_context.py`, `deploy_endpoint.py`, canary + grader scripts, integrity-assertion snippet
- **1 hook** — auto-audit after any `saveEndpoint` mutation (enabled by default; see below)
- **5 reference documents** — the full canonical corpus (2,544 lines across 4 files + a 22-pitfall catalog)
- **Cross-agent bootstrap** — `.codex/` shim for Codex; Cursor integration via repo-level `AGENTS.md` pointer

## Install

### Claude Code — local install (this machine)

```bash
# Already installed if this file exists at
#   ${CLAUDE_PLUGIN_ROOT}/
# Verify:
/plugin list | grep runpod-serverless
# If it does not show up, register:
/plugin install --local ${CLAUDE_PLUGIN_ROOT}
```

### Claude Code — marketplace install (other machines, after `gh repo create`)

```bash
/plugin marketplace add james47kjv/runpod-serverless-skills
/plugin install runpod-serverless
```

### Codex

See `.codex/INSTALL.md` for the full instructions. The two actions:

```bash
# 1. Link the plugin into Codex's search path
ln -s "$HOME/.claude/plugins/local/runpod-serverless" "$HOME/.codex/runpod-serverless"

# 2. Append the plugin's Codex block to ~/.codex/AGENTS.md
#    (AGENTS.md is Codex's authoritative session-start file, NOT agent-rules.md)
```

The AGENTS.md block to append is shown in full in `.codex/INSTALL.md`.

### Cursor

Cursor reads per-rule `.mdc` files from `~/.cursor/rules/*.mdc` (user)
or `<repo>/.cursor/rules/*.mdc` (project). Drop a file like this:

**`.cursor/rules/runpod-serverless.mdc`**

```markdown
---
description: Reference for RunPod Serverless deploys. Use when deploying a FastAPI + GPU service, auditing an endpoint, or triaging a stuck worker.
globs: ["**/deploy/runpod/**", "**/services/**/Dockerfile", "**/services/**/start.sh"]
alwaysApply: false
---

# RunPod Serverless plugin

Canonical reference:
`~/.claude/plugins/local/runpod-serverless/skills/runpod-serverless-deploy/SKILL.md`

Templates at `~/.claude/plugins/local/runpod-serverless/skills/runpod-serverless-deploy/TEMPLATES/`.

Parametrize: `<APP>`, `<GHCR_OWNER>`, `<HF_REPO>`, `<HF_REVISION>`, `<APP_REQUIRED_KEY>`.

Non-negotiables: image-based only, immutable tags, GHCR_PAT (not GITHUB_TOKEN),
integrity gates OFF in production specs, X-Lamp-Debug-Token for app-layer
debug auth (gateway consumes Authorization).
```

The plugin does not auto-install this file because Cursor rules are
user-curated. Copy the block when you want Cursor to respect it.

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
8. **Integrity gating off in production.** The two anti-cheating flags
   (your `<APP>_OFFLINE_FIXTURES` and `<APP>_DETERMINISTIC_OVERRIDES`
   equivalents) must be unset in the deploy spec. The boot-time
   integrity assertion refuses to start if they are set.
9. **App-layer auth on debug routes.** Gateway `Authorization` +
   app-layer `X-<APP>-Debug-Token` (or similar) both required. Never
   use `Authorization` for the app-layer check; the RunPod gateway
   consumes that header.

See `skills/runpod-serverless-deploy/REFERENCES/anti-cheating-contract.md`
for the full contract.

## Hook behavior (enabled)

`hooks/hooks.json` is enabled by default and ships two hooks:

1. **`SessionStart`** — prints a one-line plugin-loaded banner to stderr
   confirming skills, commands, and the plugin version.
2. **`PostToolUse`** matching `Bash` — invokes `hooks/post-tool-use.sh`,
   which reads the Bash tool payload from stdin, inspects the command
   for a `saveEndpoint` substring, and (if present) prints a drift-audit
   reminder to stderr. Read-only; never deploys; always exits 0.

Disable by removing `hooks/hooks.json` or by taking the plugin out of
`enabledPlugins` in `~/.claude/settings.json`.

## Canonical LAMP1 reference

This plugin's `REFERENCES/` contains verbatim copies of the LAMP1 canon
as of 2026-04-23:

- `runpod_serverless_setup_guide.md` — 1,022-line serverless setup guide
- `harness-guidebook.md` — 1,013-line harness architecture guide
- `red-team-handover.md` — 505-line red-team contract
- `anti-cheating-contract.md` — §11.9 integrity-gating excerpt
- `pitfalls-24.md` — consolidated 22-pitfall catalog

The source of truth is `github.com/james47kjv/lamp1/tree/main/docs/`.
This plugin is a snapshot; drift checks are manual for now — diff the
REFERENCES files against `lamp1/docs/` when you suspect divergence.

## License

MIT. Use it. Fork it. Ship to RunPod.
