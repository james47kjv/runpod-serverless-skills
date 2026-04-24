---
description: Deploy a built image to a RunPod Serverless endpoint with the full 8-step wizard (verify image → deploy → warm → canary slice → report).
argument-hint: <image-tag> [--env staging|production]
---

# /rp-deploy

**Arguments:** `$ARGUMENTS`

Execute the end-to-end deploy flow for a RunPod Serverless
LOAD_BALANCER endpoint. Invokes the `runpod-serverless-deploy` skill
checklist and the `runpod-serverless-expert` sub-agent as needed.

## Steps

Invoke the `runpod-serverless-deploy` skill via the Skill tool to load
the checklist, then execute:

1. **Parse arguments.** First arg = image tag (format
   `immutable-<UTC>-<sha>`). `--env` defaults to `staging`.
2. **Verify image exists in GHCR.** Inspect via
   `docker buildx imagetools inspect ghcr.io/<owner>/<repo>:<tag>`.
   Fail if not found.
3. **Run `deploy_endpoint.py`.** Use the appropriate spec:
   - `--env staging` → `deploy/runpod/<app>.staging.json`
   - `--env production` → `deploy/runpod/<app>.production.json`
4. **Pin `workersMin=1`** via `saveEndpoint` GraphQL mutation to
   force a warm worker. Use the clean template from
   `TEMPLATES/autonomous_deploy.sh.template` (the `throttle` function).
5. **Poll `/ping`** until `{"status":"ready"}` or 15 min timeout.
   Show elapsed time every 30s.
6. **Run a 5-question canary slice** via `redteam_canary.py --limit 5`.
7. **Report:** per-question status, any failures, latency p50, image
   tag, endpoint ID, URL.
8. **Recommend next step:** if staging green → "ready to promote to
   production"; if red → "keep staging drained, investigate".

## Guardrails

- Refuse if `--env production` is passed and the user hasn't
  explicitly run staging first in this session.
- Refuse if the image tag does not match
  `^immutable-[0-9]{8}-[0-9]{6}-[a-f0-9]{7}$`.
- Never deploy with the anti-cheating integrity flags (your
  `<APP>_OFFLINE_FIXTURES` and `<APP>_DETERMINISTIC_OVERRIDES`
  equivalents) set in the spec — flag as CRITICAL. See
  `skills/runpod-serverless-deploy/REFERENCES/anti-cheating-contract.md`.

## On completion

- Commit `release/<env>-deploy-<UTC>.json` manifest to the repo.
- If the hook `hooks/post-deploy-audit.json` is enabled, it will
  automatically run `audit_digest.py` after the `saveEndpoint`
  mutation completes.
