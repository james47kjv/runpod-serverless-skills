# 22 RunPod Serverless Pitfalls — Symptom / Root Cause / Fix

Consolidated from the LAMP1 2026-04-22 → 2026-04-23 deploy cycle. Sorted by
historical pain level. Every one of these lost us hours; skip none.

---

## Image + CI

### 1. `GITHUB_TOKEN` fails GHCR push on a fresh repo
- **Symptom:** `403 Forbidden` on first `docker push ghcr.io/<user>/...`
- **Cause:** Default `GITHUB_TOKEN` can't create user-scoped packages.
- **Fix:** Use `GHCR_PAT` (classic PAT with `write:packages`). Store in repo
  secrets AND operator `~/.env`. Referenced by every workflow.

### 2. `.env` with multi-line value breaks `source`
- **Symptom:** All secrets load as empty strings after `source ~/.env`.
- **Cause:** A multi-line string somewhere in the file terminates the
  current assignment on the first newline.
- **Fix:** Extract individual keys via
  `grep -E "^KEY=" ~/.env | head -1 | cut -d= -f2`. Never source the
  whole file.

### 3. CRLF in `start.sh` from Windows checkout
- **Symptom:** `/bin/bash^M: bad interpreter`
- **Cause:** Git on Windows converts LF to CRLF on checkout.
- **Fix:** Add `.gitattributes` with `*.sh text eol=lf`. Force re-check
  out after adding: `git rm --cached -r . && git checkout .`

### 4. CI runner runs out of disk during buildx
- **Symptom:** `no space left on device` mid-build.
- **Cause:** GitHub Actions ubuntu-latest starts with ~30 GB free; a
  vLLM+CUDA base image eats it.
- **Fix:** `sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/lib/android
  /opt/hostedtoolcache /opt/microsoft` before buildx. Also
  `docker system prune -af --volumes`.

### 5. Overwriting an immutable tag
- **Symptom:** Deployed image mysteriously changes after a later build.
- **Cause:** Workflow push step doesn't guard against tag reuse.
- **Fix:** Add `Refuse to overwrite existing immutable tag` step that
  runs `docker buildx imagetools inspect` and fails if the tag exists.

### 6. New endpoint module added, Dockerfile not updated
- **Symptom:** Worker reaches `desiredStatus=EXITED` for 10–22 min
  with no `/ping` response. Image builds clean, tests green.
- **Cause:** `services/<app>/` has multiple `.py` files but the
  Dockerfile only `COPY`s specific ones by name. A new module
  (`agent_runtime.py` in the LAMP1 case) is absent in the image.
  `services/finance_endpoint/__init__.py` shim tries to load it and
  raises; container crashes.
- **Fix:** Three guards — (a) explicit `COPY` line per new file,
  (b) add to `scripts/ci/audit_build_context.py::REQUIRED_PATHS`,
  (c) lazy-load the optional module inside try/except so a broken
  subsystem degrades to the legacy path.

### 7. GitHub Actions billing fails mid-session
- **Symptom:** `gh workflow run` returns a run that fails in 3 seconds
  with "The job was not started because recent account payments have
  failed or your spending limit needs to be increased."
- **Cause:** Account-level billing, not a code issue.
- **Fix:** Resolve at https://github.com/settings/billing. No code
  workaround. Plan for this to happen during long sessions.

---

## Runtime + model

### 8. Silent HF fetch fallback in `start.sh`
- **Symptom:** Worker boots, returns garbage.
- **Cause:** `start.sh` catches HF download error, silently continues
  with no model, vLLM picks up a stub.
- **Fix:** Loud-fail if FlashBoot cache missing AND `HF_TOKEN` unset.
  Structured JSON diagnostic. Every boot stage emits.

### 9. Child `exit(0)` treated as success
- **Symptom:** Worker quietly dies mid-session, supervisor restarts
  without diagnostic.
- **Cause:** `wait -n` returns 0 for an unexpected early exit of a
  child that was supposed to block forever.
- **Fix:** `start.sh` `wait -n` handler re-raises status 0 as exit 1.

### 10. SGLang has no FP4 GEMM on Hopper
- **Symptom:** `NotImplementedError: Current platform does not support
  w4a4 nvfp4 quantization` on Hopper pools.
- **Cause:** SGLang v0.5.10.post1 does not expose a W4A4 scheme for
  pre-Blackwell.
- **Fix:** Use vLLM v0.19.1 (`vllm/vllm-openai:v0.19.1-cu130-ubuntu2404`)
  instead. vLLM's compressed-tensors W4A4 path works on Blackwell
  (native FP4) AND Hopper (W4A16 fallback).

### 11. SGLang Blackwell path crashes in cudnn_frontend
- **Symptom:** `cudnnGraphNotSupportedError` during CUDA graph capture.
- **Cause:** SGLang v0.5.10.post1 default `flashinfer_cudnn` on
  Blackwell fails `cudnn_frontend.check_support` for NVFP4 MoE.
- **Fix:** Switch to vLLM (see pitfall 10). Do not fight an engine
  that lacks a code path for your quantization × GPU combo.

### 12. Unknown `--flag` crashes the serve command
- **Symptom:** `sglang serve: error: unrecognized arguments: --foo`
  → exit 1 → worker loop.
- **Cause:** Engine's `ServerArgs` exposes an attribute at runtime-
  config layer but NOT as a CLI flag, and the two sets drift between
  minor versions.
- **Fix:** Before baking in any flag, check `python3 -m <engine>
  --help` for your exact image tag. Put experimental flags behind
  an env-var escape hatch (`${<APP>_ENGINE_EXTRA_ARGS:-}`).

---

## RunPod API + scheduler

### 13. `saveEndpoint` GraphQL rejects spec without `gpuIds`
- **Symptom:** `gpuId(s) is required for a gpu endpoint`
- **Cause:** `gpuTypeIds` alone filters within a pool; the scheduler
  still needs a pool.
- **Fix:** Include `"gpuIds": "<POOL_ID>"` with a RunPod-canonical
  pool ID. Comma-separate for fallthrough pools. Valid 2026-04:
  `HOPPER_141`, `BLACKWELL_96`, `BLACKWELL_180`, `AMPERE_16/24/48/80`,
  `ADA_24/32_PRO/48_PRO/80_PRO`.

### 14. Single-SKU GPU pool → `throttled` in UI
- **Symptom:** Worker stuck in `throttled`, never boots.
- **Cause:** RunPod scheduler cannot allocate the requested SKU; the
  pool is exhausted.
- **Fix:** Broaden `gpuTypeIds` within one pool OR add a second pool
  in `gpuIds` comma-separated list.

### 15. Scheduler doesn't spawn despite `workersMin>=1`
- **Symptom:** `workersStandby: 1` but `workers: []`.
- **Cause:** Pool 1 unavailable and scheduler has not fallen through.
- **Fix:** Reorder `gpuIds` to put an AVAILABLE pool first. Check
  RunPod UI's "Edit Endpoint" pane — shows per-pool supply in real time.

### 16. REST `/endpoints/<id>` drifts from GraphQL state
- **Symptom:** REST shows `gpuIds: null` right after a successful
  `saveEndpoint` mutation.
- **Cause:** REST and GraphQL surfaces have different cache coherence.
- **Fix:** For ground truth read via GraphQL `myself { endpoints {
  id name gpuIds ... } }`.

### 17. Deploy script's 900s probe on a crashing worker
- **Symptom:** Deploy hangs 15 min, dies with a transport error.
- **Cause:** Worker is in crash-loop before FastAPI can answer.
- **Fix:** Independently tail worker logs via RunPod dashboard OR
  REST `/endpoints/<id>?includeWorkers=true` → worker ID → UI logs.
  Don't trust probe timeout as error source — real error is in
  engine log.

### 18. `saveEndpoint` 500 when `modelName` is included mid-rollout
- **Symptom:** `saveEndpoint` GraphQL returns 500 HTML.
- **Cause:** Including `modelName` field in a mutation body after the
  endpoint was initially created.
- **Fix:** Omit `modelName` from update-only `saveEndpoint` calls.
  It's set once on initial create via `deploy_endpoint.py` and persists
  via template. Only re-include when explicitly rotating model repo.

### 19. Scaler cascade during scale-to-zero
- **Symptom:** `workersMin=0, workersMax=N (N>0)` but worker count
  briefly INCREASES during what should be a shutdown.
- **Cause:** `REQUEST_COUNT` scaler holds a `workersStandby` target
  based on recent traffic. Replacements spawn as old workers drain.
- **Fix:** `workersMax=0` is the ONLY deterministic "off" state. Set
  it, poll until `workers=0 AND standby=0`, then restore positive max.

---

## Security + integrity

### 20. `_WORKSPACE_LOCKS` unbounded growth
- **Symptom:** Worker memory creeps up over hours; eventually OOM.
- **Cause:** Every distinct `workspace_id` added a `threading.Lock`
  with no eviction. On a long-lived worker, each question gets a
  fresh workspace_id.
- **Fix:** Cap the dict at 512 entries with LRU eviction by
  last-touch timestamp. Only unlocked entries are evicted so
  in-flight requests are safe.

### 21. Debug route relies on gateway auth only
- **Symptom:** `/v1/debug/trace/{workspace_id}` returns the full agent
  trace to any caller who has the gateway bearer.
- **Cause:** App-layer `Authorization` check was attempted, but the
  RunPod LB gateway consumes `Authorization` for its own check and
  does not forward it raw to the FastAPI app. App-layer auth never ran.
- **Fix:** Move app-layer secret to `X-Lamp-Debug-Token` header (gateway
  passes it through unmodified). Two independent auth factors:
  gateway `Authorization: Bearer <RUNPOD_API_KEY>` + app-layer
  `X-Lamp-Debug-Token: <LAMP_DEBUG_TOKEN | RUNPOD_ENDPOINT_SECRET>`.
  `hmac.compare_digest` for constant-time compare.

### 22. `q_num` benchmark coupling in production
- **Symptom:** A question that byte-matches a benchmark line returns a
  canned-string answer, even with the override dispatch flag off.
- **Cause:** `_resolve_q_num` read `public.txt` on every request and
  returned a non-None q_num on match. Downstream q_num-keyed code
  paths (engine_answer, direct_constructor) used that q_num as a
  bypass.
- **Fix:** `_resolve_q_num` returns `None` unconditionally unless
  `LAMP_OFFLINE_FIXTURES` or `LAMP_DETERMINISTIC_OVERRIDES` is set.
  Severs coupling at the root. See anti-cheating-contract.md.
