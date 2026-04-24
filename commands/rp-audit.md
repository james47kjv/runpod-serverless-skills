---
description: Run a drift audit against a live RunPod Serverless endpoint — compare the live template's image against the last release manifest. Flags drift (template shows one tag; the worker runs another).
argument-hint: <env:staging|production>
---

# /rp-audit

**Arguments:** `$ARGUMENTS`

Drift audit for a RunPod Serverless endpoint: the live template's
image ref MUST match the last `release/manifest.json` produced by CI.
Drift means the endpoint is running a different image than the repo
thinks it is.

## Steps

1. **Parse arg.** `staging` / `production`.
2. **Locate the latest release manifest** for this environment:
   - `release/<env>-deploy-*.json` (most recent by mtime), OR
   - `release/manifest.json` if a single-manifest pattern is used.
3. **Read the live endpoint state** via REST:
   ```bash
   curl -sS "https://rest.runpod.io/v1/endpoints/<ID>?includeWorkers=true" \
     -H "Authorization: Bearer $RUNPOD_API_KEY"
   ```
   Extract the template's `imageName` AND each worker's `imageName`.
4. **Compare.** Report per-field match/mismatch:
   - Manifest `image_ref` vs template's `imageName`
   - Manifest `image_digest` vs template's digest
   - Template `imageName` vs each worker's `imageName`
5. **On drift:**
   - **CRITICAL** if template points to an image that doesn't exist
     in GHCR.
   - **HIGH** if template image ≠ manifest.
   - **MEDIUM** if a worker is running a different image than the
     template (worker hasn't restarted since last template update).
6. **On match** (no drift): report "✓ no drift" with the verified
   tag + digest.

## Invocation script

```bash
cd <repo>
extract() { grep -E "^${1}=" "$HOME/.env" | head -1 | cut -d= -f2; }
RUNPOD_API_KEY=$(extract RUNPOD_API_KEY)
python scripts/serverless/audit_digest.py \
  --endpoint-id <ENDPOINT_ID> \
  --manifest release/<env>-deploy-*.json
```

If `audit_digest.py` is not present in the repo, fall back to the
inline comparison using `jq` against REST + manifest.

## When to run

- Before every production deploy (must be clean)
- After any `saveEndpoint` mutation
- When a canary suddenly regresses and you suspect image drift
- On a schedule (daily cron) for long-running deployments

## Guardrails

- Never auto-remediate drift — report only. The operator decides
  whether to roll forward (redeploy latest) or roll back (restore
  manifest's image).
- If drift exists and the operator asks to fix, escalate to
  `runpod-serverless-expert` — drift remediation is deploy-class work,
  not audit-class.
