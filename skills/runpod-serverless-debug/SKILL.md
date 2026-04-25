---
name: runpod-serverless-debug
description: Use when a RunPod Serverless deploy is stuck, failing, or behaving wrong — worker won't boot, `/ping` times out, `desiredStatus=EXITED`, UI says throttled, `workersStandby=1` but no worker visible, GHCR push 403, scaler cascade during drain, saveEndpoint 500.
---

# RunPod Serverless Debug Triage

> **Purpose.** Decision tree for diagnosing why a RunPod Serverless
> deploy is misbehaving, mapping the symptom to one of the 24 known
> pitfalls, and dispatching the correct fix.

**Version:** 2.0.0
**Sibling skills:** `runpod-serverless-deploy` (happy path),
`runpod-red-team` (canary + audit).
**Reference:** `runpod-serverless-deploy/REFERENCES/pitfalls-24.md`.

---

## When to use this skill

Trigger on any of these:

- "worker won't start" / "deploy is hanging"
- "RunPod says throttled"
- "502 on every request"
- "workers show EXITED in the UI"
- "ping times out"
- "workersStandby=1 but workers=[]"
- "GHCR push 403" / "Actions billing failed"
- "saveEndpoint returned 500"
- "worker churns: boots, runs briefly, EXITED, boots again"

Do NOT use for:

- Happy-path deploys (use `runpod-serverless-deploy`)
- Answer-quality / model-output issues (use `runpod-red-team` for canary)
- Non-RunPod platforms

---

## Triage decision tree

Answer in order; stop at the first match.

### 1. Can you reach `/ping`?

```bash
extract() { grep -E "^${1}=" "$HOME/.env" | head -1 | cut -d= -f2; }
RUNPOD_API_KEY=$(extract RUNPOD_API_KEY)
BASE=https://<ENDPOINT_ID>.api.runpod.ai
curl -sS --max-time 15 "$BASE/ping" -H "Authorization: Bearer $RUNPOD_API_KEY"
```

| Response | Meaning | Go to |
|---|---|---|
| `{"status":"ready"}` | Healthy — your problem is elsewhere (application layer) | stop; this isn't an infra issue |
| `{"status":"initializing"}` | Worker is booting; wait | step 2 |
| HTTP 502 + HTML page | RunPod gateway can't reach worker | step 2 |
| Timeout after 15s | Worker not responding | step 2 |

### 2. What does the endpoint state look like?

```bash
curl -sS "https://rest.runpod.io/v1/endpoints/<ENDPOINT_ID>?includeWorkers=true" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" | python -c "
import sys,json; d=json.load(sys.stdin)
print('min/max/standby:',d.get('workersMin'),'/',d.get('workersMax'),'/',d.get('workersStandby'))
for w in d.get('workers',[]):
    print(f\"  {w.get('id')}: status={w.get('desiredStatus')} lastStart={w.get('lastStartedAt')} img=...{w.get('imageName','')[-35:]}\")"
```

**Before reading the table below, check `locations` / `dataCenterIds` first.** GraphQL: `{ myself { endpoints { id name locations workersStandby } } }`. If `locations` is anything other than null/empty, the endpoint is region-pinned and the scheduler can only see GPUs in that region — you'll get `workersStandby=1, workers=0` indefinitely even when RunPod has free capacity elsewhere. **Endpoints must be GLOBAL.** Fix: re-deploy with the spec's `dataCenterIds`/`locations` keys removed (the deploy script must serialize `null` for `locations`, not a region list). See pitfall #20 below.

| Pattern | Likely pitfall | Fix |
|---|---|---|
| `min/max` are `0/0` | endpoint is drained | set `workersMin=1, workersMax=1` via saveEndpoint |
| `locations: "US"` / `["EU-RO-1"]` / any non-null region value | **pitfall 20** — region-pinned endpoint can't draw from RunPod's global GPU fleet | re-deploy with `locations=null`; remove `dataCenterIds`/`locations` from the spec (also see pitfall #21 below — the deploy script must hard-reject specs that try to set them) |
| `min=1, max=1, standby=1`, workers list shows EXITED from >1h ago | stale worker record; new spawn pending | wait; RunPod API shows the last worker even after it's gone. Poll `/ping` every 30s for up to 15 min |
| `min=1, max=1, standby=1`, workers list empty | **pitfall 15** — pool unavailable, scheduler hasn't fallen through (FIRST verify the endpoint is GLOBAL — region-pinning is the more common cause and looks identical) | reorder `gpuIds` with a higher-supply pool first (check RunPod UI's "Edit Endpoint" pane for real-time supply) |
| `min=1, max=1, standby=0`, workers empty | **pitfall 14** — single-SKU pool exhausted (`throttled` in UI) | broaden `gpuTypeIds` within the pool OR add a fallback pool to `gpuIds` |
| Worker has imageName ending in your latest tag, status=RUNNING, but /ping still times out for >5 min | **pitfall 6** — module missing from Dockerfile COPY OR (**pitfall 23** — start.sh asserts on `/runpod-volume/...` cache path which doesn't exist on a no-NV serverless endpoint) | check Dockerfile `COPY` manifest against `services/<app>/` file listing; check `scripts/ci/audit_build_context.py::REQUIRED_PATHS`; look for ImportError in worker logs; verify start.sh doesn't precondition on `/runpod-volume/...` (anchor cache at `/root/.cache/huggingface` instead) |
| Worker imageName is the OLD tag | `deploy_endpoint.py` didn't actually update the template | re-run deploy script; confirm templateId in spec matches the endpoint's templateId |
| Worker boots, RUNNING for ~30-60s, then `Exited by Runpod` with empty Container logs panel and System logs say only `worker exited with exit code 1` | **pitfall 23** — start.sh hits `set -e` failure before any echo flushes (most often the `/runpod-volume/...` precondition described above) | add `dump_tails` helper to start.sh that emits last 80 lines of `/tmp/{uvicorn,vllm,tei}.log` on every failure path; redirect each child's stdout/stderr to those files; emit a `start_sh_entered` echo at the very top so you can prove the script ran |

### 3. Is the CI build itself failing?

```bash
gh run list --repo <OWNER>/<REPO> --workflow build-image.yml --limit 3 \
  --json status,conclusion,displayTitle,createdAt \
  -q '.[]|"\(.createdAt) \(.status)/\(.conclusion) \(.displayTitle)"'
```

| Conclusion | Likely pitfall | Fix |
|---|---|---|
| `failure` in 3s with "recent account payments have failed" | **pitfall 7** — GitHub Actions billing | resolve at github.com/settings/billing; no code workaround |
| `failure` with GHCR 403 | **pitfall 1** — `GITHUB_TOKEN` can't push user-scoped packages | switch workflow login step to `GHCR_PAT` |
| `failure` with "no space left on device" | **pitfall 4** — runner disk exhausted | add aggressive pre-build cleanup step |
| `failure` with "Refusing to overwrite existing immutable tag" | **pitfall 5** — tag reuse attempt | bump the tag; immutable tags are write-once by design |
| `success` but worker never boots | back to step 2 |

### 4. Is the GraphQL saveEndpoint failing?

| Symptom | Likely pitfall | Fix |
|---|---|---|
| 500 HTML page returned from `saveEndpoint` | **pitfall 18** — `modelName` included in update mutation | omit `modelName` from update-only saveEndpoint calls; it's set once at create via deploy_endpoint.py |
| `gpuId(s) is required for a gpu endpoint` | **pitfall 13** — missing `gpuIds` | add a pool ID (HOPPER_141, BLACKWELL_96, etc.) |
| `REST /endpoints/<id>` shows `gpuIds: null` right after saveEndpoint | **pitfall 16** — REST/GraphQL cache drift | trust GraphQL `myself { endpoints { ... gpuIds ... } }` |

### 5. Is the drain not finishing?

| Symptom | Likely pitfall | Fix |
|---|---|---|
| Set `workersMin=0, workersMax=N>0` but worker count stays nonzero or climbs | **pitfall 19** — scaler cascade | use `workersMax=0` — the ONLY deterministic off-state. See deploy skill §Clean-drain procedure |

### 6. Is the worker crashing immediately?

`rest.runpod.io/v1/endpoints/<id>?includeWorkers=true` shows a worker
that cycles RUNNING → EXITED in <60s.

| Worker log shows | Likely pitfall | Fix |
|---|---|---|
| `/bin/bash^M: bad interpreter` | **pitfall 3** — CRLF in start.sh | add `*.sh text eol=lf` to `.gitattributes` |
| `ImportError: No module named ...` | **pitfall 6** — missing Dockerfile COPY OR hyphenated-dir shim broken | explicit COPY line for every .py file needed at runtime |
| `cudnnGraphNotSupportedError` | **pitfall 11** — SGLang Blackwell crash | switch to vLLM v0.19.1 |
| `NotImplementedError: ... does not support w4a4 nvfp4` | **pitfall 10** — SGLang no FP4 on Hopper | switch to vLLM v0.19.1 |
| `unrecognized arguments: --foo` | **pitfall 12** — unknown flag | check `python3 -m <engine> --help` for your exact image tag |
| Silent exit 0 | **pitfall 9** — `exit(0)` treated as success | `wait -n` handler in start.sh must re-raise 0 as 1 |
| HF model download error | **pitfall 8** — silent HF fetch fallback | start.sh must loud-fail if FlashBoot cache missing AND `HF_TOKEN` unset |

### 7. If none of the above match

Escalate to the `runpod-incident-responder` sub-agent:

```
Task(subagent_type="runpod-incident-responder",
     prompt="<ENDPOINT_ID> is <symptom>; I've ruled out pitfalls <X>. Deep-dive.")
```

It arrives with the full pitfalls catalog + canonical guide loaded.

---

## Log-retrieval commands

Quick reference for pulling log data you'll need:

```bash
# Endpoint state + workers
curl -sS "https://rest.runpod.io/v1/endpoints/<ID>?includeWorkers=true" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" | python -m json.tool

# Worker logs — RunPod REST does NOT expose these; use the RunPod web UI:
# https://www.runpod.io/console/serverless/<endpoint_id>/workers
# Click the worker → Logs tab. Export as needed.

# CI build logs
RUN_ID=$(gh run list --repo <OWNER>/<REPO> --workflow build-image.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run view --repo <OWNER>/<REPO> "$RUN_ID" --log-failed
```

---

## When to escalate

Match these against your symptom — escalate to the expert sub-agent
if you see TWO or more:

- Multiple bounce cycles (drain→warm→drain) fail the same way
- You've verified the image IS on the worker via REST but /ping still hangs
- Image was just built cleanly and CI passed, but the same endpoint worked on the previous image
- The symptom appears only on one GPU pool and not others

That pattern suggests an integration issue worthy of a fresh pair of
eyes. Spin up `runpod-incident-responder` with the evidence you've
already gathered.
