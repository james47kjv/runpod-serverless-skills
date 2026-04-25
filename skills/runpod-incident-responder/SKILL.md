---
name: runpod-incident-responder
description: Use when a workflow asks for the RunPod incident responder sub-agent or when triaging a stuck, failing, throttled, EXITED, or unreachable RunPod Serverless endpoint.
---

# RunPod Incident Responder Persona

Use this skill when a workflow asks for the
`runpod-incident-responder` sub-agent or when triaging a live RunPod
Serverless incident.

Codex does not expose custom plugin sub-agent types through
`spawn_agent`. Treat this skill as the Codex-native entry point for the
same persona.

Before acting, read:

```bash
cat ~/.codex/runpod-serverless/agents/runpod-incident-responder.md
```

Then execute the persona instructions yourself. Also read the
`runpod-serverless-debug` skill before changing endpoint state.
