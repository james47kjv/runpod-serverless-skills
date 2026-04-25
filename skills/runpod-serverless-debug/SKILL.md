---
name: runpod-serverless-debug
description: Use when a RunPod Serverless deploy is stuck, failing, or behaving wrong — worker won't boot, `/ping` times out, `desiredStatus=EXITED`, UI says throttled, `workersStandby=1` but no worker visible, GHCR push 403, scaler cascade during drain, saveEndpoint 500.
---

# RunPod Serverless Debug Triage

> **Purpose.** Decision tree for diagnosing why a RunPod Serverless
> deploy is misbehaving, mapping the symptom to one of the 35 known
> pitfalls, and dispatching the correct fix.

**Version:** 2.0.0
**Sibling skills:** `runpod-serverless-deploy` (happy path),
`runpod-red-team` (canary + audit).
**Reference:** `runpod-serverless-deploy/REFERENCES/pitfalls-35.md`.

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

**Before reading the table below, do these ELEVEN zero-cost checks first — they are the eleven silent killers and look identical to real boot failures:**

1. **Check Dockerfile's `ENTRYPOINT` is set explicitly (NOT `[]`).** `grep -E "^ENTRYPOINT|^CMD" <Dockerfile>` — must show `ENTRYPOINT ["bash", "/app/start.sh"]` (or similar explicit script invocation), NOT `ENTRYPOINT []`. RunPod's runtime does not reliably honor empty-array ENTRYPOINT and falls back to the base image's inherited entrypoint, which then runs your `dockerStartCmd` as args (e.g. TEI's `cuda-all-entrypoint.sh` `exec`s `text-embeddings-router-XX "$@"`, treating "bash" as the model ID). Symptom: `dockerStartCmd` IS verifiably set on the worker, PORT_HEALTH IS set, but `start_sh_entered` STILL doesn't appear in Container logs and worker exits 1 in <60s. Pattern is invariant across every GPU pool and every region — that invariance is the tell. Fix: set `ENTRYPOINT ["bash", "/app/start.sh"]` and `CMD []` in Dockerfile, rebuild image. See pitfall #27.

2. **Check `dockerStartCmd` is set in the spec.** `python -c "import json; print(json.load(open('<spec>.json')).get('dockerStartCmd'))"` — must return a non-empty list like `["bash", "/app/start.sh"]`, NOT `None`. If missing, RunPod ignored your Dockerfile's `CMD` and fell back to the base image's CMD (TEI / TGI / vLLM / NIM / Whisper all ship one). The base binary ran with no args and died instantly — your `start.sh` never executed. Symptom: worker EXITED `exit code 1`, **Container logs panel is completely empty** (not even the `start_sh_entered` echo at the top of start.sh). Pattern repeats identically across every retry, every GPU pool, every region. Fix: add `"dockerStartCmd": ["bash", "/app/start.sh"]` to the spec. See pitfall #26.

3. **Check `PORT_HEALTH` is set on the spec env.** RunPod's LB health-poller looks at `PORT_HEALTH` (NOT `PORT`) to find `/ping`. If it's missing, the worker boots cleanly and serves `/ping` 204/200 internally, but the gateway never sees it and the endpoint stays `unhealthy`/`initializing` forever — with **no error in any log** because nothing is broken. Verify via `printenv | grep PORT_HEALTH` on the worker (must show a value, NOT "NOT SET"). After patching the spec, you MUST kill the worker pod (`podStop` GraphQL on the worker pod ID, NOT the endpoint) — RunPod does not recycle workers on env-only changes. See pitfall #25.

4. **Check `locations` / `dataCenterIds`.** GraphQL: `{ myself { endpoints { id name locations workersStandby } } }`. If `locations` is anything other than null/empty, the endpoint is region-pinned and the scheduler can only see GPUs in that region — you'll get `workersStandby=1, workers=0` indefinitely even when RunPod has free capacity elsewhere. **Endpoints must be GLOBAL.** Fix: re-deploy with the spec's `dataCenterIds`/`locations` keys removed (the deploy script must serialize `null` for `locations`, not a region list). See pitfall #23.

5. **Check `/ping` returns 204 with NO body.** `grep -B2 -A6 "status_code=204" <app.py>` — the initializing branch must be `return Response(status_code=204)` with NO `content`, NO `media_type`. RFC 9110 §15.3.5 forbids a body on 204; RunPod's LB gateway HANGS trying to parse a 204+body, causing external `/ping` to time out forever even though the worker is alive and responding internally. Symptom: worker `desiredStatus=RUNNING` for 15+ min, gateway accepts auth, container `/ping` returns 204 from `127.0.0.1`, but external `/ping` always times out. Fix: `return Response(status_code=204)` with no other args. See pitfall #29.

6. **Check HF cache READS from `/runpod-volume/huggingface-cache/hub` (not `/tmp`).** `grep "HUGGINGFACE_HUB_CACHE\|/runpod-volume" <start.sh|boot.py> <spec>.json` — the runtime detection should set `HUGGINGFACE_HUB_CACHE=/runpod-volume/huggingface-cache/hub` when present (RunPod's host-disk cache, populated by `spec.modelName`). If you anchor at `/tmp/...`, you ignore RunPod's pre-cached snapshot and re-download the entire model on every scale-up — looks identical to "FlashBoot is broken" but is just a path bug. Symptom: first `/ping` cold-start takes ~match-the-model-size-in-MB-divided-by-30 seconds (5+ min for big models), often timing out at the gateway. **`/runpod-volume` here is NOT a user-attached Network Volume** — it's a host-local cache mount, does NOT pin region (different from pitfall #23). Container logs should show `hf_cache_resolved` event with `location: runpod-host`. If `location: tmp-fallback`, you have this bug. Fix: two-tier detection — read from `/runpod-volume` if present, write to `/tmp/hf-home`. See pitfall #30.

7. **Check that cache assignments use UNCONDITIONAL `=` (not `:=` or `setdefault`).** `grep -nE ': *"\${HUGGINGFACE_HUB_CACHE|HF_HOME):=' <start.sh>` and `grep -nE 'setdefault.*(HUGGINGFACE|HF_)' <boot.py>` — ANY match is the bug. Bash `:=` and Python `setdefault` are default-on-unset operators; they DO NOTHING when the var is already set. Inference base images preset `HUGGINGFACE_HUB_CACHE=/data` (TEI), `HF_HOME=/root/.cache/huggingface` (vLLM), etc. — your override is silently ignored, the worker reads the base image's preset, downloads/fails. **Worst symptom: the diagnostic emits `hf_cache_resolved` saying `location: runpod-host` because that's a separate `CACHE_LOCATION` shell var — but the actual `HUGGINGFACE_HUB_CACHE` is `/data`.** Diagnostic LIES. Only way to detect from outside is to extract the deployed image config and check the `Env` array. Fix: change `: "${VAR:=...}"` to `VAR="..."` (bash); change `os.environ.setdefault(K, V)` to `os.environ[K] = V` (python). See pitfall #31.

8. **Check spec env keys match what app.py actually reads.** Run the parity audit:
   ```bash
   grep -nE 'os\.getenv\(\s*"[A-Z_0-9]+"' <app>/app.py \
     | sed -E 's/.*os\.getenv\(\s*"([^"]+)".*/\1/' | sort -u > /tmp/app-keys
   python -c "import json; print('\n'.join(sorted(json.load(open('<spec>.json'))['env'].keys())))" > /tmp/spec-keys
   comm -23 /tmp/spec-keys /tmp/app-keys
   ```
   ANY line printed by `comm -23` is a silent override — the spec sets a key the app never reads. Common shape: spec sets `MODEL_PATH` but app reads `QWEN3_RERANKER_MODEL_PATH` → spec falls through to stale pod-based default → worker dies with `RuntimeError: model path does not exist: /runpod-volume/models/<old-default>`. Fix: rename spec keys to match app, or add fallback chain. See pitfall #32.

9. **Check `_target` background-load thread sets `_load_error` on exception.** `grep -B1 -A6 'def _target' <app>/app.py` — the `except` block MUST set `self._load_error = f"{type(exc).__name__}: {exc}"`. If only `LOGGER.exception(...)` is present, that's the bug: thread dies silently, `load_state()` returns "idle", next /ping spawns a fresh thread that crashes identically, /ping returns 204 (initializing) FOREVER, gateway hangs external requests until executionTimeoutMs. The traceback IS in container logs but never affects /ping's contract — the diagnostic is right but the response contract LIES. Fix: set `self._load_error` so /ping returns 500 on terminal failure. See pitfall #33.

10. **Check Dockerfile sets `HF_HUB_ENABLE_HF_TRANSFER=0` OR requirements.txt includes `hf_transfer`.** `grep -q "HF_HUB_ENABLE_HF_TRANSFER=0" <worker>/Dockerfile || grep -qiE "^hf.transfer" <worker>/requirements.txt` MUST succeed. If neither, base images (runpod/pytorch, vllm/vllm-openai, TEI) preset `HF_HUB_ENABLE_HF_TRANSFER=1` in image ENV but `hf_transfer` is an optional package — every snapshot_download / hf_hub_download raises `ValueError: Fast download using 'hf_transfer' is enabled but 'hf_transfer' package is not available`, then `ModuleNotFoundError: No module named 'hf_transfer'`. Model never loads. Fix: set `HF_HUB_ENABLE_HF_TRANSFER=0` in Dockerfile ENV (preferred — bakes into image) AND/OR in spec env (overrides without rebuild). See pitfall #34.

11. **Check `containerDiskInGb` and `gpuIds` are right-sized.** Compute `model_size_gb + 5 + (5 if vLLM else 0)` rounded UP to nearest 5 — that's the maximum sane `containerDiskInGb`. If the spec value is >2× this, that's pitfall #35: scheduler can only place workers on hosts with enough free disk; over-sized request shrinks the eligible host pool by 3-5×. Same for `gpuIds` — a 4B model fits in 24 GB VRAM, so restricting to 48 GB+ pools (`AMPERE_48,ADA_48_PRO`) excludes the 24 GB pool which is 5-10× larger. Symptom: workers stuck in "Rented by User" state forever, never progressing to Resumed/RUNNING; or "Exited by Runpod" without container logs; `workersStandby=1, workers=0` for extended periods despite global capacity. Fix: right-size `containerDiskInGb` per the formula; broaden `gpuIds` to the smallest pool that fits the model's VRAM budget. See pitfall #35.

> **Order matters.** Run check #1 before #2 because pitfall #27 (ENTRYPOINT hijack) makes pitfall #26 (`dockerStartCmd`) appear "fixed" while still failing — the spec field is set but the inherited entrypoint hijacks it. Both can be present simultaneously; check the Dockerfile FIRST.

| Pattern | Likely pitfall | Fix |
|---|---|---|
| `min/max` are `0/0` | endpoint is drained | set `workersMin=1, workersMax=1` via saveEndpoint |
| Worker is RUNNING but endpoint stays `unhealthy`; container `/ping` returns 204 to `127.0.0.1` but external `/ping` times out; `printenv` on the worker shows `PORT_HEALTH=NOT SET` | **pitfall 25** — missing `PORT_HEALTH` env; RunPod's LB poller uses `PORT_HEALTH`, not `PORT`, so it never reaches `/ping` | add `PORT_HEALTH` to spec env (same value as `PORT`), redeploy, then **explicitly kill the worker pod** via `podStop` GraphQL — env changes don't recycle workers automatically |
| `locations: "US"` / `["EU-RO-1"]` / any non-null region value | **pitfall 23** — region-pinned endpoint can't draw from RunPod's global GPU fleet | re-deploy with `locations=null`; remove `dataCenterIds`/`locations` from the spec (the deploy script must also hard-reject specs that try to set them) |
| `min=1, max=1, standby=1`, workers list shows EXITED from >1h ago | stale worker record; new spawn pending | wait; RunPod API shows the last worker even after it's gone. Poll `/ping` every 30s for up to 15 min |
| `min=1, max=1, standby=1`, workers list empty | **pitfall 15** — pool unavailable, scheduler hasn't fallen through (FIRST verify the endpoint is GLOBAL — region-pinning is the more common cause and looks identical) | reorder `gpuIds` with a higher-supply pool first (check RunPod UI's "Edit Endpoint" pane for real-time supply) |
| `min=1, max=1, standby=0`, workers empty | **pitfall 14** — single-SKU pool exhausted (`throttled` in UI) | broaden `gpuTypeIds` within the pool OR add a fallback pool to `gpuIds` |
| Worker has imageName ending in your latest tag, status=RUNNING, but /ping still times out for >5 min | **pitfall 25** (missing `PORT_HEALTH` — check first, costs nothing) OR **pitfall 6** (module missing from Dockerfile COPY) OR **pitfall 24** (start.sh asserts on `/runpod-volume/...` cache path which doesn't exist on a no-NV serverless endpoint) | check `printenv \| grep PORT_HEALTH` on worker first; then check Dockerfile `COPY` manifest against `services/<app>/` file listing; check `scripts/ci/audit_build_context.py::REQUIRED_PATHS`; look for ImportError in worker logs; verify start.sh doesn't precondition on `/runpod-volume/...` (anchor cache at `/root/.cache/huggingface` instead) |
| Worker imageName is the OLD tag | `deploy_endpoint.py` didn't actually update the template | re-run deploy script; confirm templateId in spec matches the endpoint's templateId |
| Worker boots, RUNNING for ~30-60s, then `Exited by Runpod` with empty Container logs panel and System logs say only `worker exited with exit code 1` | **FIRST suspect pitfall 26** — `dockerStartCmd` missing from spec, base image's CMD hijacked the boot, your start.sh never ran (no `start_sh_entered` line proves this). **If `dockerStartCmd` IS set, suspect pitfall 31** — Dockerfile uses `ENTRYPOINT []` and the inherited entrypoint hijacks dockerStartCmd as args. **Last resort: pitfall 24** — start.sh hits `set -e` failure before any echo flushes. | (1) `python -c "import json; print(json.load(open('<spec>.json')).get('dockerStartCmd'))"` — if `None`, add `["bash", "/app/start.sh"]` and redeploy. (2) Read Dockerfile `ENTRYPOINT` line — if `[]`, change to explicit `["bash", "/app/start.sh"]` and rebuild. (3) Add `dump_tails`, redirect children to `/tmp/*.log`, emit `start_sh_entered` BEFORE `set -e`. |
| Worker EXITED `exit code 1`, identical pattern across ALL GPU pools and ALL regions, Container logs panel empty even after multiple retries on different SKUs | almost certainly **pitfall 26 OR 27** — base image hijacked the boot via either CMD (pitfall 26: missing `dockerStartCmd`) or ENTRYPOINT (pitfall 31: Dockerfile uses `ENTRYPOINT []` instead of explicit). The cross-pool / cross-region invariance is the tell — if it were a code bug, GPU-CUDA mismatch, or HF download issue, you'd see at least SOME variation across retries. | first add `"dockerStartCmd": ["bash", "/app/start.sh"]` to the spec; if that doesn't help, set `ENTRYPOINT ["bash", "/app/start.sh"]` (NOT `ENTRYPOINT []`) in the Dockerfile and rebuild |
| `dockerStartCmd` IS verifiably set on the worker (REST `?includeWorkers=true` confirms), but `start_sh_entered` STILL doesn't appear in Container logs and worker still exits 1 in <60s | **pitfall 31** — base image's ENTRYPOINT script hijacks the boot even when `dockerStartCmd` is set, because Dockerfile uses `ENTRYPOINT []` which RunPod's runtime doesn't honor reliably. The inherited entrypoint (e.g. TEI's `cuda-all-entrypoint.sh` ending in `exec text-embeddings-router-XX "$@"`) runs your `dockerStartCmd` as args. | in Dockerfile, set `ENTRYPOINT ["bash", "/app/start.sh"]` and `CMD []`. Rebuild image. The `start_sh_entered` echo should appear within seconds of the next deploy. |

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
