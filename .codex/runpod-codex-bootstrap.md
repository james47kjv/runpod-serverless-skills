# runpod-serverless — Codex Bootstrap

<EXTREMELY_IMPORTANT>

You have access to the **runpod-serverless** plugin (v2.0.0) at
`~/.codex/runpod-serverless/`.

## Skills available

Read the full content of the SKILL.md via `cat`/`Read`:

| Skill | When to use | Path |
|---|---|---|
| `runpod-serverless-deploy` | Deploy any FastAPI + GPU service to RunPod Serverless | `~/.codex/runpod-serverless/skills/runpod-serverless-deploy/SKILL.md` |
| `runpod-serverless-debug` | Triage a broken RunPod deploy (EXITED, throttled, /ping times out) | `~/.codex/runpod-serverless/skills/runpod-serverless-debug/SKILL.md` |
| `runpod-red-team` | Audit + canary a deployed RunPod endpoint | `~/.codex/runpod-serverless/skills/runpod-red-team/SKILL.md` |

**Critical rule:** If the user's request matches any of these triggers,
you MUST read the skill BEFORE responding. Announce: "Reading the
[skill-name] skill from runpod-serverless plugin."

## References (deep-dive — read on demand)

When a skill's checklist points at a specific § or when you need more
depth:

| Reference | Size | Contents |
|---|---|---|
| `runpod_serverless_setup_guide_v2.md` | 1022 lines | Full LAMP1 serverless setup guide |
| `harness-guidebook.md` | 1013 lines | Full harness architecture guide |
| `red-team-handover.md` | 633 lines | Full red-team audit contract |
| `anti-cheating-contract.md` | 147 lines | Integrity-gating invariants |
| `pitfalls-37.md` | 200 lines | Symptom/cause/fix for all 37 pitfalls |

Located at `~/.codex/runpod-serverless/skills/runpod-serverless-deploy/REFERENCES/`.

## Templates (copy into target repo)

12 starter files at
`~/.codex/runpod-serverless/skills/runpod-serverless-deploy/TEMPLATES/`.
Copy and parametrize `<APP>`, `<OWNER>`, `<HF_REPO>`, `<HF_REVISION>`,
`<APP_REQUIRED_KEY>`.

## Sub-agent personas

Codex does NOT have `Task(subagent_type=...)`. When a Claude-native
workflow says "delegate to X sub-agent", read the persona doc and
follow its instructions YOURSELF:

| Persona | Path | Used for |
|---|---|---|
| runpod-serverless-expert | `agents/runpod-serverless-expert.md` | Designing new deploys |
| runpod-red-team-auditor | `agents/runpod-red-team-auditor.md` | Independent audit + canary |
| runpod-incident-responder | `agents/runpod-incident-responder.md` | Live incident triage |

## Slash commands (workflow recipes, not shortcuts)

Codex has no `/rp-*` shortcuts. Read the command doc and execute its
steps via Bash:

| Command | Read at | What it does |
|---|---|---|
| rp-deploy | `commands/rp-deploy.md` | 8-step deploy wizard |
| rp-canary | `commands/rp-canary.md` | Run both canaries + grade |
| rp-drain | `commands/rp-drain.md` | Clean-drain both endpoints |
| rp-warm | `commands/rp-warm.md` | Pin workersMin=1 and poll /ping |
| rp-audit | `commands/rp-audit.md` | Drift audit vs release manifest |

## Claude primitive → Codex equivalent

| Claude has | Codex does | How |
|---|---|---|
| `Skill(skill="...")` tool | `cat ~/.codex/runpod-serverless/skills/<name>/SKILL.md` | Read directly |
| `Task(subagent_type="...")` | Read the persona, execute yourself | You become the sub-agent |
| `/rp-*` slash commands | Read the command doc, execute steps | Bash-only |
| `hooks/*` auto-triggers | Manual invocation after every relevant tool call | Run `audit_digest.py` after every `saveEndpoint` |
| `TodoWrite` auto-population from checklists | Your `update_plan` tool | Convert CHECKLIST bullets manually |

## The non-negotiable contract (memorize)

Every RunPod Serverless deploy MUST satisfy:

1. Image-based only — no `networkVolumeId`
2. Immutable tags — `immutable-<UTC>-<sha>` — never overwrite
3. Model via `modelName` + `flashboot: true` — weights NOT baked in
4. Staging + production specs differ only in workers + env label
5. Drift audit before every production deploy
6. No silent failures in `start.sh`
7. `GHCR_PAT`, not `GITHUB_TOKEN`, for GHCR login
8. Integrity gates OFF in production (`LAMP_OFFLINE_FIXTURES`,
   `LAMP_DETERMINISTIC_OVERRIDES` must be unset)
9. App-layer auth on debug routes via `X-Lamp-Debug-Token` header
   (NOT `Authorization` — the gateway consumes that)

If the user asks you to skip any of these, refuse and cite
anti-cheating-contract.md.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

</EXTREMELY_IMPORTANT>
