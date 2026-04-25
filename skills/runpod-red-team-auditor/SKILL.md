---
name: runpod-red-team-auditor
description: Use when a workflow asks for the RunPod red-team auditor sub-agent, endpoint audit, canary scoring, leak checks, or independent verification of a deployed endpoint.
---

# RunPod Red-Team Auditor Persona

Use this skill when a workflow asks for the `runpod-red-team-auditor`
sub-agent or when independently auditing a RunPod Serverless endpoint.

Codex does not expose custom plugin sub-agent types through
`spawn_agent`. Treat this skill as the Codex-native entry point for the
same persona.

Before acting, read:

```bash
cat ~/.codex/runpod-serverless/agents/runpod-red-team-auditor.md
```

Then execute the persona instructions yourself. Also read the
`runpod-red-team` skill before running endpoint canaries or security
checks.
