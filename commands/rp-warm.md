---
description: Warm a RunPod Serverless endpoint by pinning workersMin=1, workersMax=1, then polling /ping until ready or 15 min timeout. Use before any canary run or Vals.ai submission.
argument-hint: <env:staging|production>
---

# /rp-warm

**Arguments:** `$ARGUMENTS`

Pin the endpoint's workers to `min=1, max=1` and poll `/ping` with
visible progress until `{"status":"ready"}` or 15-minute timeout.

## Steps

1. **Parse arg.** `staging` / `production`. No default — always explicit.
2. **Read endpoint config.** ID, name, templateId from
   `deploy/runpod/<app>.<env>.json`.
3. **Execute `saveEndpoint`** with `workersMin=1, workersMax=1`,
   `gpuIds: "BLACKWELL_96,BLACKWELL_180,HOPPER_141"`.
4. **Poll `/ping`** every 15s, showing elapsed time:
   ```
   [15s]  ping=err (still cold)
   [30s]  ping=err (still cold)
   [165s] ping={"status":"ready"}
   === READY at 165s ===
   ```
5. **If not ready by 15 min:** report endpoint state (worker
   `desiredStatus`, last-start timestamp, workersStandby), suggest
   running `/rp-drain <env>` + wait + try again, OR invoke
   `runpod-serverless-debug` skill for triage.
6. **Report** final worker ID + image tag for confirmation.

## Guardrail

After warming, the operator should do their canary or Vals submission
quickly. Every minute warm costs ~$0.03 on Blackwell. When done,
`/rp-drain <env>` to stop the burn.

## Cold-start expectations

| Scenario | Expected |
|---|---|
| Image already on host (FlashBoot hit) | 263s |
| Fresh host (image pull + model download) | 5-10 min |
| First-ever spawn on this endpoint | up to 15 min |
| Stale EXITED worker (last spawn >30 min ago) | 5-10 min (fresh host chosen) |

If > 15 min, something is wrong — use `runpod-serverless-debug` skill's
triage decision tree.
