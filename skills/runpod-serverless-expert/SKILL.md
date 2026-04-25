---
name: runpod-serverless-expert
description: Use when designing or executing a RunPod Serverless deployment plan as the expert persona. Reads the canonical persona doc and applies it directly in Codex.
---

# RunPod Serverless Expert Persona

Use this skill when a workflow asks for the `runpod-serverless-expert`
sub-agent or when the task needs expert planning for a RunPod
Serverless endpoint.

Codex does not expose custom plugin sub-agent types through
`spawn_agent`. Treat this skill as the Codex-native entry point for the
same persona.

Before acting, read:

```bash
cat ~/.codex/runpod-serverless/agents/runpod-serverless-expert.md
```

Then execute the persona instructions yourself. Do not substitute the
deprecated v1 skill. Use the v2 plugin skills and references under
`~/.codex/runpod-serverless/`.
