---
description: Drain RunPod Serverless endpoints to workersMax=0 via the scaler-cascade-safe clean-drain procedure. Only workersMax=0 is the deterministic off-state.
argument-hint: [staging|production|all]
---

# /rp-drain

**Arguments:** `$ARGUMENTS`

Drain one or both endpoints to `workersMin=0, workersMax=0`. This is
the ONLY deterministic off-state — `workersMin=0, workersMax=N>0` can
spawn replacements via the REQUEST_COUNT scaler (pitfall 19).

## Steps

1. **Parse arg.** `staging` / `production` / `all` (default `all`).
2. **For each endpoint** in scope:
   - Read endpoint ID, name, templateId from
     `deploy/runpod/<app>.<env>.json` (or prompt user if ambiguous).
   - Execute `saveEndpoint` mutation with `workersMin=0, workersMax=0`.
   - Poll `workers=0 AND standby=0` via REST every 20s (typically
     <90s total).
3. **Report final state:** per-endpoint `workersMin/Max/Standby`,
   worker-count transition over time, total drain duration.
4. **Reminder:** if you just canary'd and need to re-warm for another
   run, use `/rp-warm <env>` — don't re-enable `workersMin=1` as the
   drain restore.

## GraphQL mutation pattern

```bash
extract() { grep -E "^${1}=" "$HOME/.env" | head -1 | cut -d= -f2; }
RUNPOD_API_KEY=$(extract RUNPOD_API_KEY)

curl -sS "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
  -d '{"query":"mutation { saveEndpoint(input: { id: \"<ID>\", name: \"<NAME>\", templateId: \"<TID>\", gpuIds: \"BLACKWELL_96,BLACKWELL_180,HOPPER_141\", gpuCount: 1, workersMin: 0, workersMax: 0, idleTimeout: 60, scalerType: \"QUEUE_DELAY\", scalerValue: 4, type: \"LB\", flashBootType: FLASHBOOT }) { id workersMin workersMax } }"}'
```

## Poll

```bash
poll_count() {
  curl -sS --max-time 10 "https://rest.runpod.io/v1/endpoints/$1?includeWorkers=true" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{len(d.get('workers') or [])} {d.get('workersStandby')}\")"
}
until [[ "$(poll_count <ID>)" == "0 0" ]]; do sleep 20; done
```

## Guardrail

Do NOT include `modelName` in the `saveEndpoint` mutation body (pitfall
18). This drain mutation touches worker counts only.
