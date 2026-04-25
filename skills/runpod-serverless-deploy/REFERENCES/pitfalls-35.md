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

### 23. Region-pinned endpoint can't draw from RunPod's GLOBAL fleet
- **Symptom:** Endpoint sits at `workersStandby=1, workers=0` with
  `/ping` timing out indefinitely; UI eventually marks newly-spawned
  workers `throttled`. GraphQL `myself { endpoints { locations } }`
  returns a single region (`"US"`, `"EU-RO-1"`, etc.) instead of `null`.
- **Cause:** Spec contains `dataCenterIds` / `locations` /
  `dataCenterPriority` / `region` / `regionId` / `zoneId` /
  `countryCodes`. The RunPod scheduler can only see GPUs in that
  region. With pool fallthrough (`gpuIds` left→right) the search
  exhausts inside the region and stops — RunPod won't reach across
  regions to find a 4090 even when one is sitting idle in another DC.
- **Fix:** **Endpoints must be GLOBAL.** Remove all region keys from
  the spec. The deploy script must serialize `locations: null` (or
  omit the field) on the saveEndpoint payload. CI must run an audit
  that fails the build if any spec contains those keys (see
  `scripts/ci/audit_no_region_pinning.py`). The deployer itself
  should `_reject_region_pinning` at runtime as defense-in-depth.
  Region-pinning is for POD endpoints with a regional network volume —
  never for serverless GPU endpoints. See setup-guide §6.1.1.

### 24. start.sh asserts on `/runpod-volume/...` cache path that doesn't exist on serverless
- **Symptom:** Worker boots, RUNNING for a few seconds, then EXITED
  with exit code 1. RunPod Console "Container" logs panel is
  completely empty; "System" tab only says `worker exited with exit
  code 1`. Pattern repeats on every retry. Eventually RunPod throttles.
- **Cause:** `start.sh` has `[ -d /runpod-volume/huggingface-cache/...
  ] || exit 1` as a precondition check. On serverless endpoints
  WITHOUT a network volume attached (which is the standard pattern —
  network volumes pin a region, see pitfall #23), `/runpod-volume`
  doesn't exist as a writable path. Under `set -euo pipefail` the
  check fails before any `echo` flushes, so logs are empty.
- **Fix:**
  1. Anchor the HF cache inside the writable container disk:
     `export HF_HOME=/root/.cache/huggingface
      export HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface
      mkdir -p "$HUGGINGFACE_HUB_CACHE"`
  2. Let the inference runtime (TEI / vLLM / transformers) own its
     own cache; `huggingface_hub.snapshot_download(cache_dir=...)`
     is idempotent and pulls only what's missing.
  3. Pipe each child's stdout/stderr to a log file
     (`uvicorn ... > /tmp/uvicorn.log 2>&1 &`) and on every failure
     path emit `tail -n 80 /tmp/*.log`. RunPod's Console panel for
     LB endpoints is unreliable; tee'd logs are your forensic trail.
  4. Emit an unconditional `start_sh_entered` echo at the very top
     of `start.sh` so you can prove the script ran at all.
  5. FlashBoot keeps the first-pull cache warm on the host across
     scale cycles — you only pay the full download once per host.

### 25. Missing PORT_HEALTH env → LB health-poller can't find /ping → worker `unhealthy` forever
- **Symptom:** Worker boots cleanly. Container logs show FastAPI/uvicorn
  serving `GET /ping → 204` (or `200`) from `127.0.0.1`. The endpoint
  in the RunPod Console stays `initializing` / `unhealthy` indefinitely.
  External requests to `https://<id>.api.runpod.ai/ping` time out or
  return `502`. There is **no error in any log** — the symptom looks
  identical to a real boot failure but no code path is broken.
- **Cause:** RunPod's LB health-poller looks at the env var
  `PORT_HEALTH` (NOT `PORT`) to decide which port to hit for `/ping`.
  If the spec env only has `PORT=8000`, the poller sees no
  `PORT_HEALTH`, falls back to "unknown", and never pings the worker
  at all. The worker keeps serving `/ping` on `:8000` to nobody.
- **Detection:**
  1. `printenv | grep -E '^(PORT|PORT_HEALTH)='` on the worker shows
     `PORT=8000` and **`PORT_HEALTH=NOT SET`** (or absent).
  2. Worker container `/ping` returns `204` from inside, but external
     `curl https://<id>.api.runpod.ai/ping` times out.
  3. GraphQL `myself.endpoint(id) { workersHealthy }` is `0` despite
     `workers >= 1` and `workersStandby >= 1`.
- **Fix:**
  1. Add `PORT_HEALTH` to the spec `env` block — same value as `PORT`
     when `/ping` shares the application port, or a separate port if
     `/ping` runs on its own health-only HTTP server.
  2. **Explicitly kill the worker pod** (`podStop` GraphQL on the
     worker pod ID, NOT the endpoint) so a fresh worker spawns with
     the new env. RunPod does NOT recycle workers on env-only
     changes; patching the spec and waiting will not fix it.
  3. The deploy script MUST refuse to push any LOAD_BALANCER spec
     whose `env` does not include `PORT_HEALTH` — add this guard
     alongside the region-pinning audit (pitfall #23). This is the
     ONLY way to prevent the silent recurrence; logs alone will
     never reveal the cause because the worker itself is healthy.
  4. In `start.sh`, bind FastAPI to `${PORT_HEALTH:-${PORT}}` for the
     `/ping` route, and emit a structured WARNING
     (`stage=boot, event=port_health_unset`) when `PORT_HEALTH` is
     unset so the diagnostic appears in the worker log even when the
     gateway never reaches the worker.
- **Reference:** setup-guide §6.1.2.

### 26. Missing `dockerStartCmd` → base image's CMD hijacks boot → start.sh never runs → `exit code 1` with empty Container logs
- **Symptom:** Worker spawns. RunPod UI shows it in `RUNNING` for ~5–60s,
  then EXITED with `worker exited with exit code 1`. The Container
  logs panel is **completely empty** — not a single line, not even the
  `start_sh_entered` echo at the top of your start.sh. System logs
  show only the `exit code 1` line. The pattern is identical across
  all GPU pools, all regions, all retries. Looks identical to a
  corrupt image, a permissions bug, or `set -e` failing before any
  echo flushes — but is none of those.
- **Cause:** RunPod's worker runtime does NOT honor your Dockerfile's
  `CMD ["bash", "/app/start.sh"]` when the base image already
  declares its own `CMD` or `ENTRYPOINT`. Most modern inference base
  images do — `ghcr.io/huggingface/text-embeddings-inference`,
  `ghcr.io/huggingface/text-generation-inference`,
  `vllm/vllm-openai`, NVIDIA's NIM containers, OpenAI Whisper
  containers, faster-whisper, and others all ship a default CMD
  that launches the model server binary directly. Even with
  `ENTRYPOINT []` and `CMD ["bash", "/app/start.sh"]` in your
  Dockerfile, RunPod can fall back to the base image's CMD. The
  base binary then starts with no required args and exits in
  milliseconds — too fast to flush stdout to RunPod's log capture.
  Your start.sh never runs.
- **Detection:**
  1. `python -c "import json; print(json.load(open('<spec>.json')).get('dockerStartCmd'))"` returns `None` or an empty list.
  2. The `start_sh_entered` echo (which should be the FIRST executable line of every start.sh) does not appear in the Container logs panel.
  3. `docker inspect <base_image>` shows a non-empty `Cmd` or `Entrypoint`. Most ML base images do.
- **Fix:**
  1. Add `"dockerStartCmd": ["bash", "/app/start.sh"]` to every spec
     (path must match where Dockerfile copies start.sh — typically
     `/app/start.sh` for a flat layout, `/app/services/<app>/start.sh`
     for a multi-service repo).
  2. Redeploy. Within seconds the Container logs panel should show
     `start_sh_entered`, then `cache_root`, then `fastapi_started`,
     then whatever your script does next.
  3. The deploy script MUST refuse any spec missing `dockerStartCmd`
     — add this guard alongside `_require_port_health` (pitfall #25)
     and `_reject_region_pinning` (pitfall #23). These three checks
     together block the three silent killers.
- **Defense in depth in start.sh:** the first executable line (after
  shebang and `set -euo pipefail`) MUST emit
  `{"event":"start_sh_entered","ts":"..."}` to stdout. The presence
  of this line in Container logs is positive proof the script ran.
  If you see "exit code 1" without this line, the bug is upstream
  of start.sh — almost certainly missing `dockerStartCmd`.
- **Reference:** setup-guide §6.1.3.

### 27. Base image's ENTRYPOINT hijacks `CMD` / `dockerStartCmd` even when Dockerfile sets `ENTRYPOINT []`
- **Symptom:** Worker spawns. RUNNING for 1–60s. EXITED with `worker
  exited with exit code 1`. **Container logs panel is completely
  empty** — not even the `start_sh_entered` echo at the very top of
  start.sh. `dockerStartCmd` IS verifiably set on the worker (REST
  `?includeWorkers=true` shows the field). `PORT_HEALTH` IS set.
  Every other "silent killer" pitfall (#23, #24, #25, #26) is ruled
  out, yet the symptom is identical to all of them. Pattern repeats
  exactly across every GPU pool, every region, every retry. The
  cross-pool / cross-region invariance is the tell.
- **Cause:** Modern ML inference base images (Hugging Face TEI, TGI,
  vLLM, NIM, Whisper, faster-whisper, NVIDIA's PyTorch+CUDA bases,
  etc.) ship a non-trivial `ENTRYPOINT` that performs setup (CUDA
  detection, library path tweaks, etc.) and then `exec`s the model
  server with `"$@"`. Concrete example from TEI's
  `cuda-all-entrypoint.sh`:
  ```bash
  exec text-embeddings-router-${compute_cap} "$@"
  ```
  The Docker spec says `ENTRYPOINT []` clears the inherited entrypoint
  and lets `CMD` run as the container's first process. **RunPod's
  container runtime does NOT honor `ENTRYPOINT []` reliably.** It
  preserves the inherited ENTRYPOINT and passes your CMD (or
  `dockerStartCmd`) as arguments to it. Result:
  `text-embeddings-router-80 bash /app/start.sh` — the router treats
  "bash" as the model ID, fails arg-parsing in milliseconds, exits 1.
  Your start.sh never runs. No logs.
- **Detection:**
  1. Read your Dockerfile's `ENTRYPOINT` line. If it's `[]`, you have
     this bug as soon as your base image declares its own ENTRYPOINT.
  2. `docker inspect <base_image>` (or read the upstream Dockerfile)
     and look at the `Entrypoint` field. If it's a script path, that
     script is what's running, not your `start.sh`.
  3. Worker REST `?includeWorkers=true` shows `dockerStartCmd` IS set
     correctly. PORT_HEALTH IS set. Cache path IS writable. Yet still
     "exit code 1, empty logs". This combination = pitfall #27.
- **Fix:** in the Dockerfile, set an EXPLICIT entrypoint, not empty:
  ```dockerfile
  ENTRYPOINT ["bash", "/app/start.sh"]
  CMD []
  ```
  This forces your script to BE the entrypoint regardless of what the
  inherited entrypoint did. Pair it with `"dockerStartCmd": ["bash",
  "/app/start.sh"]` in the spec for defense in depth — two independent
  layers that both point at the same correct invocation, so either one
  catches what the other misses.
- **Why not just `ENTRYPOINT []`?** Per the OCI image spec it should
  work, and it does on plain Docker. RunPod's worker runtime,
  Kubernetes pod runtimes, and several other orchestrators have buggy
  or incomplete handling of the empty-array case — they fall back to
  the inherited entrypoint silently. An explicit
  `ENTRYPOINT ["bash", "/app/start.sh"]` produces identical behavior on
  every runtime.
- **Defense in depth in start.sh:** the very first executable line —
  BEFORE `set -euo pipefail` — must emit
  `{"event":"start_sh_entered","ts":"...","whoami":"...","uid":...}`.
  Putting it before `set -e` guarantees it flushes even if every
  subsequent line fails. The `whoami`/`uid` fields tell you the
  runtime user. The presence of this line in Container logs is
  positive proof your script ran. If you ever see "exit code 1"
  without it, the cause is upstream of start.sh — almost always this
  pitfall (#27) or pitfall #26 (missing `dockerStartCmd`).
- **Cost-of-discovery on the v8 nonnon rollout:** ~6 hours. Every
  fix we shipped first (pitfalls #24, #25, #26, broadened gpuIds,
  region audit) was correct in its own right, but none of them helped
  because the inherited TEI entrypoint short-circuited every boot
  before any of them took effect. Found by reading TEI's upstream
  `cuda-all-entrypoint.sh` and noticing the trailing `exec ... "$@"`.
- **Reference:** setup-guide §6.1.4.

### 28. Base image binary not on PATH — bare-name invocation in start.sh fails 127
- **Symptom:** Worker spawns. `start_sh_entered` echo IS in Container logs
  (so #27 ruled out — start.sh did run). Other diagnostic echoes appear up
  to the model-server launch line. Then exit code 1 in <1s. The launch
  command failed with "command not found" but the message may be missed
  by RunPod's log shipper for sub-second exits. Across most of the GPU
  pool, the failure is identical; on H100/H200 (cap 90), B200/Blackwell
  (cap 120), or T4 (cap 75) the worker may "accidentally" boot if you
  hand-rolled compute-cap-suffixed binary lookup.
- **Cause:** Many ML inference base images do NOT ship a binary with the
  obvious name. Examples (verified directly against the GHCR images):
  - `huggingface/text-embeddings-inference:cuda-latest` ships ONLY:
    `text-embeddings-router-75`, `-80`, `-90`, `-100`, `-120`. No plain
    `text-embeddings-router`. Compute caps 86 and 89 (every A-series,
    every Ada Generation, RTX 30/40 series, L4/L40/L40S) bucket-map to
    `-80` via the upstream `/entrypoint.sh` script — there is no
    `text-embeddings-router-86` or `-89` binary on disk.
  - `huggingface/text-generation-inference` similarly hides the actual
    binary behind `text-generation-launcher` + entrypoint script.
  - `vllm/vllm-openai` doesn't ship a `vllm` CLI; you call it as
    `python3 -m vllm.entrypoints.openai.api_server`.
  - `nvcr.io/nvidia/nim-llm:*` invocations go through `/opt/nim/start_server.sh`
    not a top-level binary.
- **Detection:** the `start_sh_entered` line (and any other diagnostic
  echoes ABOVE the failed model-server launch) DO appear in Container
  logs — this is the key distinguisher from pitfall #27. Verify the
  binary name by extracting the base image:
  ```bash
  docker pull <base-image>
  docker create --name probe <base-image> /bin/true
  docker export probe | tar -tvf - | grep -E 'text-embed|text-gen|vllm' | head -20
  ```
  Or read the upstream Dockerfile and entrypoint script.
- **Fix:** call the base image's upstream dispatcher script, not a bare
  binary name. For TEI's CUDA image: `/entrypoint.sh` (NOT the misleading
  `cuda-all-entrypoint.sh` — that's the upstream Dockerfile filename, but
  in the built image it's renamed to `/entrypoint.sh` at FS root). For
  TGI: `text-generation-launcher`. For vLLM: `python3 -m vllm.entrypoints.openai.api_server`.
  Background-launching the dispatcher is safe even though TEI's ends in
  `exec text-embeddings-router-XX "$@"` — the `exec` replaces the child
  shell with the model-server binary, so the PID we captured (`$!`)
  becomes the model server itself.
- **Why NOT to write your own bucket logic:** if you naively write
  `text-embeddings-router-${COMPUTE_CAP}` after computing
  `CAP=$(nvidia-smi --query-gpu=compute_cap | tr -d '.')`, you'll hit
  `-89` and `-86` for every Ada/Ampere/L-series GPU and there's no
  binary at those names. The upstream script's bucket logic
  (`>=80 && <90 -> -80`) is non-obvious from the binary list. ALWAYS
  delegate to the upstream dispatcher.
- **Cost-of-discovery on the v8 nonnon-embedder rollout:** ~2 hours
  AFTER fixing pitfalls #25, #26, #27. Found by spawning a parallel
  diagnostic sub-agent that extracted the actual GHCR image layers and
  enumerated the binaries on disk. Before that fix, every GPU SKU in
  our broadened pool was guaranteed to crash because none of them had
  a compute_cap whose suffix existed as a binary (we got rented an
  RTX 4000 Ada — cap 89 — and the lookup for `-89` failed every time).
- **Reference:** setup-guide §6.1.5.

### 29. `/ping` returns HTTP 204 WITH a body — RunPod LB gateway hangs
- **Symptom:** Worker stays `RUNNING` for 15+ min (does NOT crash, does
  NOT exit). RunPod LB gateway accepts auth (no 401 from external
  `/ping`), forwards the request to the worker, but the gateway times
  out after 30+ seconds. From inside the container, `curl
  http://127.0.0.1:8000/ping` works fine and returns 204 with a JSON
  body. Pitfalls #25 (PORT_HEALTH), #26 (dockerStartCmd), #27
  (ENTRYPOINT hijack), #28 (binary not on PATH) are ALL ruled out:
  worker is alive, dockerStartCmd is set, ENTRYPOINT is explicit,
  start.sh ran (start_sh_entered echo visible), uvicorn is bound,
  FastAPI is responding internally. The endpoint is just permanently
  unreachable from outside.
- **Cause:** RFC 9110 §15.3.5 forbids a body on a 204 No Content
  response. RunPod's LB gateway hangs trying to parse a 204 that
  carries `Content-Length: N` and `Content-Type: application/json`
  with a body. Most reverse proxies do something with violating 204s:
  - Nginx, Envoy: silently strip the body, request "succeeds"
  - HAProxy: returns 502 to the client
  - AWS ALB: tolerates it
  - **RunPod LB: hangs the request until gateway timeout**
- **Detection:**
  1. Worker desiredStatus = RUNNING for >5 min, never EXITED.
  2. Internal `/ping` test (e.g. `kubectl exec` or any in-container
     curl) returns 204 quickly.
  3. External `/ping` through `https://<id>.api.runpod.ai/ping` with
     Bearer auth times out (NOT 401, NOT 502 — pure timeout).
  4. The FastAPI handler has `Response(content=..., media_type="...",
     status_code=204)`.
- **Fix:** in app.py, change the initializing branch of `/ping` to
  `return Response(status_code=204)` with NO `content`, NO
  `media_type`, NO body of any kind. The 200 response (when ready)
  keeps its JSON body since 200 permits one.
  ```python
  @app.get("/ping")
  def ping() -> Response:
      if READY_FILE.exists():
          return Response(
              content=json.dumps({"status": "healthy", "ts": time.time()}),
              media_type="application/json",
              status_code=200,
          )
      return Response(status_code=204)   # NO body, NO content-type
  ```
- **Why this is so hard to spot:** every other "RUNNING but unreachable"
  symptom in this catalog (#25-#28) presents identically. The temptation
  is to assume the worker is broken when actually a single byte of
  response body is making the LB gateway hang. **Always inspect the
  /ping handler first** when troubleshooting "worker alive but
  external /ping times out" — it's a 5-second check that rules out a
  real failure mode.
- **Defense in depth:** in start.sh, add a localhost self-test loop
  AFTER launching uvicorn that polls `http://127.0.0.1:${PORT}/ping`
  for up to 10s and dumps uvicorn.log + exits 1 if it fails. Catches
  both "uvicorn never bound" and "uvicorn bound but /ping returns
  invalid response" before the LB gateway ever pokes the worker.
- **Cost-of-discovery on the v8 nonnon-embedder rollout:** ~30 minutes
  AFTER pitfalls #25, #26, #27, #28 were all correctly fixed. Found by
  spawning a parallel diagnostic sub-agent to read the deployed image's
  app.py and noticing the 204 was sending `Content-Length` + JSON.
- **Reference:** setup-guide §6.1.6.

### 30. HF cache anchored at `/tmp` defeats RunPod's "Cached Models" feature → every scale-up re-downloads
- **Symptom:** Endpoint deploys cleanly. `/ping` works on the first
  request after deploy (eventually — takes 3-5 min). After
  `idleTimeout` elapses and the worker scales to zero, the next
  request takes another 3-5 min for `/ping` to come back, and often
  times out at the gateway. Operator concludes "FlashBoot is broken
  for me, but works for everybody else", reaches for `workersMin=1`
  + `flashBootType=OFF` to "fix" it, defeats the entire serverless
  cost model. **This is the single most common cause of
  "FlashBoot doesn't work" reports.**
- **Cause:** RunPod's "Cached Models" feature (triggered by setting
  `spec.modelName`) pre-stages the model snapshot on the HOST DISK
  at `/runpod-volume/huggingface-cache/hub/models--<org>--<name>/snapshots/<rev>/`.
  This makes scale-from-zero fast (no model download — just GPU init).
  But if your `start.sh` sets `HUGGINGFACE_HUB_CACHE=/tmp/hf-cache`,
  TEI / vLLM / transformers ignore the host cache and download fresh
  to `/tmp` — which gets wiped between containers. So every scale-up
  costs a full model re-download, defeating FlashBoot entirely.
- **Critical terminology trap:** `/runpod-volume` here is NOT a
  user-attached "Network Volume" (NV). User NVs pin the endpoint to
  a region (pitfall #23). The Cached Models mount uses the same
  path PREFIX but is a different mechanism — host-local, does NOT
  pin region. **Same prefix, opposite consequences.** This trap is
  what caused pitfall #24's incorrect "fix" of anchoring cache at
  `/tmp` (the fix was right that the bare precondition check was
  a problem, but wrong that the cache should move).
- **Detection:**
  1. `grep "HUGGINGFACE_HUB_CACHE" <start.sh|boot.py> <spec>.json`
     — if the value is `/tmp/...` rather than
     `/runpod-volume/huggingface-cache/hub`, you have this bug.
  2. In Container logs, look for `hf_cache_resolved` event. If
     `location` is `tmp-fallback`, you're paying the download
     cost on every spawn.
  3. Time `/ping` cold-start. If it consistently takes ~match-the-
     model-size-in-MB-divided-by-30-MB-per-sec instead of <60s,
     you're downloading not reading from cache.
- **Fix (the LAMP1 plugin reference pattern, two-tier):**
  ```bash
  # READ from RunPod's host cache when present
  RUNPOD_HUB_CACHE="/runpod-volume/huggingface-cache/hub"
  if [[ -d "$RUNPOD_HUB_CACHE" ]]; then
      : "${HUGGINGFACE_HUB_CACHE:=$RUNPOD_HUB_CACHE}"
      CACHE_LOCATION="runpod-host"
  else
      : "${HUGGINGFACE_HUB_CACHE:=/tmp/hf-cache}"
      CACHE_LOCATION="tmp-fallback"
  fi
  # WRITE — keep HF_HOME on /tmp for tokens/non-cache state
  : "${HF_HOME:=/tmp/hf-home}"
  mkdir -p /tmp/hf-cache /tmp/hf-home
  mkdir -p "$HUGGINGFACE_HUB_CACHE" 2>/dev/null || true
  export HUGGINGFACE_HUB_CACHE HF_HOME
  echo "{\"event\":\"hf_cache_resolved\",\"location\":\"$CACHE_LOCATION\",\"hub_cache\":\"$HUGGINGFACE_HUB_CACHE\"}"
  ```
  For Python entry-point workers (boot.py spawning app.py), do
  the same with `os.environ.setdefault(...)` BEFORE the subprocess
  spawn. The env propagates to the child app.py process.
- **Spec env MUST NOT hard-code `HF_HOME` or `HUGGINGFACE_HUB_CACHE`** —
  let runtime detection in start.sh / boot.py decide. If you set
  these in the spec, you've defeated the runtime detection (env
  values from spec take priority over our `: "${VAR:=...}"` defaults
  unless we use `=` instead).
- **Why two tiers (read on host, write on /tmp):** `/runpod-volume`
  may be read-only in some host configurations. HF lib needs a
  writable HF_HOME for tokens and non-cache state. Two paths keeps
  reads on the host cache (fast), writes on /tmp (always works).
- **What "FlashBoot" actually does:** pre-stages the container image
  AND model snapshot on the host disk. Every scale-from-zero is a
  FRESH container — your `start.sh` runs from the top, your Python
  process is brand new, no socket/CUDA state restored. FlashBoot is
  a *disk cache*, not a *process snapshot*. The `lastStatusChange="Resumed by user"`
  field in the worker's REST response does NOT mean "FlashBoot
  snapshot resume" — it just means the most recent state change was
  user-initiated (saveEndpoint mutation, podStop, request-triggered
  scale-up). Don't form theories from that field.
- **When `flashBootType: OFF` is appropriate:** almost never. If
  you reach for it to "fix" `/ping` timeouts, you're masking one
  of the silent killers (#25-#30). Find the actual cause.
- **Cost-of-discovery on the v8 nonnon rollout:** ~4 hours. Found
  by reading RunPod's official "Cached Models" docs and noticing
  the path matched the OLD pre-pitfall-24 design that the prior
  v8 architect had used. Pitfall #24's "fix" (anchor cache at
  /tmp) was a real bug in start.sh's precondition check — but the
  remedy was wrong (should have made the precondition non-fatal
  while keeping `/runpod-volume` as the cache).
- **Reference:** setup-guide §6.1.7.

### 31. Bash `:=` and Python `setdefault` are NO-OPs when the base image presets the env var
- **Symptom:** Your start.sh / boot.py emits a `hf_cache_resolved` event
  showing `location: runpod-host` (or any custom diagnostic label),
  yet the worker behaves as if the cache resolution NEVER took effect:
  TEI/vLLM/transformers download the model fresh on every spawn,
  scale-from-zero is multi-minute, often gateway-times-out, exact
  pattern of pitfall #30 (HF cache anchored at /tmp). But your code
  CLEARLY says `/runpod-volume/...` — and the diagnostic confirms it.
  **The diagnostic LIES.** What's actually exported is the base
  image's preset value, not yours.
- **Cause:** Inference base images preset cache-path env vars in their
  image ENV. Verified examples:
  - `huggingface/text-embeddings-inference:cuda-latest` →
    `HUGGINGFACE_HUB_CACHE=/data`
  - `vllm/vllm-openai` → `HF_HOME=/root/.cache/huggingface`
  - several NVIDIA NIM bases → similar presets
  Bash `: "${VAR:=default}"` and Python `os.environ.setdefault(K, V)`
  are BOTH default-on-unset operators — they only assign when the
  variable is unset OR empty. When the base image has already set
  the var (to ANYTHING non-empty), these idioms do NOTHING. Your
  intended override is silently ignored.
- **Why so insidious:**
  1. Local `bash -n start.sh` says syntax OK (it IS valid bash).
  2. Local `bash dry-run.sh` works correctly because your local
     environment doesn't have the base image's preset.
  3. Your diagnostic emit's `location` field is correct (you set
     a separate `CACHE_LOCATION` shell variable from the if/elif),
     so the log lies — it claims you're using the right path while
     `HUGGINGFACE_HUB_CACHE` is actually still `/data`.
  4. The only way to detect it from outside RunPod is to extract
     the deployed image's config JSON (skopeo / docker inspect)
     and check the `Env` array for the offending preset.
- **Cost-of-discovery on the v8 nonnon rollout:** ~12 hours, 7
  commits, 3 wrong hypotheses (snapshot resume corruption, GPU
  compute-cap mismatch, /runpod-volume read-only mount). Found by
  a diagnosis sub-agent that did `skopeo copy` of the deployed
  image to a CPU pod, extracted all 22 layers, and reproduced the
  bash `:=` no-op locally with `HUGGINGFACE_HUB_CACHE=/data
  bash dry-run.sh`.
- **Fix:** UNCONDITIONAL assignment.
  Bash:
  ```bash
  HUGGINGFACE_HUB_CACHE="$RUNPOD_HUB_CACHE"   # NOT  : "${HUGGINGFACE_HUB_CACHE:=$RUNPOD_HUB_CACHE}"
  HF_HOME="/tmp/hf-home"                        # NOT  : "${HF_HOME:=/tmp/hf-home}"
  export HUGGINGFACE_HUB_CACHE HF_HOME
  ```
  Python:
  ```python
  os.environ["HUGGINGFACE_HUB_CACHE"] = target  # NOT  os.environ.setdefault("HUGGINGFACE_HUB_CACHE", target)
  os.environ["HF_HOME"] = "/tmp/hf-home"        # NOT  setdefault
  ```
- **General rule for `=` vs `:=` / `setdefault` vs direct assignment:**
  - Use default-on-unset (`:=` / `setdefault`) ONLY when you want
    the operator to be able to override via spec env.
  - Use unconditional assignment (`=` / `os.environ[k]=v`) when
    you're overriding a value the base image is likely to preset.
  - For HF / TORCH / TRANSFORMERS / VLLM / TEI / NIM cache paths
    and runtime mode flags: ALWAYS unconditional. Base images
    preset these.
- **Detection in code review:**
  ```bash
  # Bash — any of these near a base-image-presetable env var is suspect
  grep -nE ': *"\$\{(HUGGINGFACE_HUB_CACHE|HF_HOME|TRANSFORMERS_CACHE|TORCH_HOME|HF_HUB_CACHE):=' start.sh
  # Python — same for setdefault
  grep -nE 'setdefault.*(HUGGINGFACE|HF_|TRANSFORMERS|TORCH)' boot.py
  ```
  Any match = fix before deploying.
- **Diagnostic best practice:** emit BOTH the location label AND the
  actual value of the env var. If they ever disagree, the bug is back:
  ```bash
  echo "{\"event\":\"hf_cache_resolved\",\"location\":\"$CACHE_LOCATION\",\"hub_cache\":\"$HUGGINGFACE_HUB_CACHE\"}"
  ```
- **Reference:** setup-guide §6.1.8.

### 32. Spec-app env-var name mismatch (the silent override that does nothing)
- **Symptom:** Worker boots fine, FastAPI binds, /ping returns 204
  (initializing). Container logs show
  `RuntimeError: model path does not exist: /runpod-volume/models/<old-default-name>`
  repeating every few seconds. **That path isn't what your spec sets.**
  You "fixed" the path by adding it to spec env, redeployed, the same
  wrong path is still in the error.
- **Cause:** Spec sets one env-var name, app code reads a DIFFERENT
  env-var name. Common shape:
  ```jsonc
  // Spec
  "env": { "MODEL_PATH": "james47kjv/nonnon-reranker" }
  ```
  ```python
  # app.py
  MODEL_PATH = os.getenv("QWEN3_RERANKER_MODEL_PATH",
                         "/runpod-volume/models/Qwen3-Reranker-8B")
  ```
  `MODEL_PATH` IS set on the worker, but `os.getenv("QWEN3_RERANKER_MODEL_PATH", ...)`
  reads a DIFFERENT key, falls through to the stale pod-based default.
- **Why it survives review:** both names look right in isolation. The
  spec's `MODEL_PATH` is the obvious logical concept; the app's
  `QWEN3_RERANKER_MODEL_PATH` is a more-specific namespaced version.
  Substrings overlap but don't grep-collide.
- **Cost-of-discovery on the v8 nonnon rollout:** ~45 minutes (would
  have been hours without #33's silent-failure fix exposing the
  underlying error).
- **Fix:** Pick ONE:
  1. Rename spec keys to match the app (faster, no rebuild).
  2. Add fallback chain in app: `os.getenv("MODEL_PATH") or os.getenv("QWEN3_RERANKER_MODEL_PATH", default)` (safer, requires rebuild).
  3. Pick a single canonical env-var name across all workers (best
     long-term, requires rewrite).
- **Detection:** static parity audit per (spec, app.py) pair.
  ```bash
  # Every os.getenv key the app reads
  grep -nE 'os\.getenv\(\s*"[A-Z_0-9]+"' <app>/app.py \
    | sed -E 's/.*os\.getenv\(\s*"([^"]+)".*/\1/' | sort -u > /tmp/app-keys
  # Every env key the spec sets
  python -c "import json; print('\n'.join(sorted(json.load(open('<spec>.json'))['env'].keys())))" > /tmp/spec-keys
  # Spec keys that the app never reads
  comm -23 /tmp/spec-keys /tmp/app-keys
  ```
  Any line printed by `comm -23` is a silent override.
- **CI gate:** `scripts/ci/audit_spec_app_env_parity.py` should run this
  for every (spec, app.py) pair and fail the build on any unread key.
- **Reference:** setup-guide §6.1.9.

### 33. Background load swallows exception → /ping stuck at 204 forever
- **Symptom:** Worker boots, FastAPI binds, /ping returns 204
  (initializing) and stays 204 forever. Container logs show
  `ERROR:nonnon_<service>:Background preload failed` plus a Python
  traceback every few seconds. Gateway hangs external requests until
  `executionTimeoutMs`.
- **Cause:** "Load model in background thread on first /ping" pattern
  with the bug:
  ```python
  def start_background_load(self) -> None:
      if self.load_state() in {"ready", "error", "loading"}:
          return                                          # idempotent
      def _target() -> None:
          try:
              self.load()
          except Exception:
              LOGGER.exception("Background preload failed")  # ← BUG
      self._loading_thread = threading.Thread(target=_target, daemon=True)
      self._loading_thread.start()
  ```
  The `except` swallows the exception (logs it but doesn't propagate).
  Thread dies. `_load_error` was never set. Next /ping:
  `load_state()` checks tokenizer (None) → `_load_error` (None, not "error")
  → `_loading_thread.is_alive()` (False) → returns "idle".
  `start_background_load()` sees "idle", spawns fresh thread, crashes
  identically. **Loop forever.** /ping keeps returning 204 because state
  never becomes "error".
- **Why insidious:** the traceback IS in container logs — but it never
  affects /ping's contract because `_load_error` stays None. Operators
  read the traceback, fix the underlying cause (e.g. wrong model path),
  redeploy, the load STILL fails for a different reason, same crash-loop.
  The diagnostic is correct but the response contract LIES — there's no
  terminal-failure signal.
- **Cost-of-discovery on the v8 nonnon rollout:** ~30 minutes once we
  noticed the /ping=204 + traceback contradiction. Would have been
  hours longer if dashboard logs weren't visible.
- **Fix:**
  ```python
  def _target() -> None:
      try:
          self.load()
      except Exception as exc:
          # Set _load_error so /ping returns 500 (terminal failure)
          # instead of looping back to 204 (initializing) forever.
          self._load_error = f"{type(exc).__name__}: {exc}"
          LOGGER.exception("Background preload failed")
  ```
  Now /ping returns:
  - 200 if `_loaded is not None` → ready
  - 500 if `_load_error is not None` → terminal failure (RunPod scheduler
    sees 5xx and can react)
  - 204 if `_loading_thread.is_alive()` → genuinely in-progress
- **Detection:**
  ```bash
  grep -B1 -A6 'def _target' <app>/app.py | grep -E 'except.*:|self\._load_error'
  ```
  If you see `except Exception:` in `_target` without a corresponding
  `self._load_error = ...` line in the same block, that's the bug.
- **General principle:** any "load in background, /ping reflects state"
  pattern needs THREE state transitions, not two:
  - idle/loading → 204 (in-progress)
  - ready → 200 (success)
  - **error → 500 (terminal failure)**
  Skipping the third = the gateway hangs forever instead of responding
  with the actual error.
- **Reference:** setup-guide §6.1.10.

### 34. Base image presets `HF_HUB_ENABLE_HF_TRANSFER=1` but `hf_transfer` package not installed
- **Symptom:** Worker boots, FastAPI binds. Container logs show:
  ```
  ValueError: Fast download using 'hf_transfer' is enabled
  (HF_HUB_ENABLE_HF_TRANSFER=1) but 'hf_transfer' package is not
  available in your environment. Try `pip install hf_transfer`.

  During handling of the above exception, another exception occurred:

  ModuleNotFoundError: No module named 'hf_transfer'
  ```
  `snapshot_download` and `hf_hub_download` BOTH honor this env var.
  If set to `1` (truthy) but the package isn't installed, every HF
  download attempt raises immediately — the model never loads.
  /ping returns 204 forever (or 500 if you've fixed pitfall #33).
- **Cause:** Several common base images preset
  `HF_HUB_ENABLE_HF_TRANSFER=1` in their image ENV layer:
  - `runpod/pytorch:*-cu*-torch*-ubuntu*` — preset on most variants
  - `vllm/vllm-openai:*` — preset
  - some `huggingface/text-embeddings-inference:*` variants
  - TGI and NIM images often preset it too
  Your worker's `requirements.txt` doesn't include `hf_transfer` (it's
  an optional dep), and your Dockerfile's `ENV` block doesn't override
  the preset to `0`. Result: HF downloads fail before the model can load.
- **Cost-of-discovery on the v8 nonnon rollout:** ~10 minutes (post-#33
  fix exposed the actual error). Would have been hours without #33.
- **Fix:** TWO defensive layers — set BOTH:
  1. **Dockerfile** (preferred — bakes into image):
     ```dockerfile
     ENV HF_HUB_ENABLE_HF_TRANSFER=0 \
         HF_HOME=/tmp/hf-cache \
         HUGGINGFACE_HUB_CACHE=/tmp/hf-cache \
         HF_HUB_DISABLE_TELEMETRY=1
     ```
  2. **Spec env** (overrides without rebuild):
     ```jsonc
     "env": { "HF_HUB_ENABLE_HF_TRANSFER": "0", ... }
     ```
  If you genuinely want the speedup, install the package instead:
  ```diff
  # requirements.txt
  +hf_transfer>=0.1.6
  ```
  Unless the worker downloads >1 GB models on every cold-start,
  `hf_transfer` adds complexity for marginal gain. Disabling is safer.
- **Detection per worker:**
  ```bash
  # Dockerfile must set the override OR requirements.txt must include the package
  ( grep -q "HF_HUB_ENABLE_HF_TRANSFER=0" <worker>/Dockerfile \
    || grep -qiE "^hf.transfer" <worker>/requirements.txt ) \
    && echo "OK: $worker" \
    || echo "BUG: $worker"
  ```
- **Why missed in audit:** workers were authored independently from
  the same template; some Dockerfiles included the override, others
  didn't. Bug hides until the first deploy on a fresh host with no
  FlashBoot cache (cached snapshots bypass the download path entirely).
- **Reference:** setup-guide §6.1.11.

### 35. `containerDiskInGb` over-provisioned → scheduler can't find a host
- **Symptom:** Worker spawning is slow or unreliable. RunPod scheduler
  shows `workersStandby=1, workers=0` for extended periods. Workers
  occasionally appear at `desiredStatus=EXITED` with
  `lastStatusChange="Rented by User"` but never progress to `Resumed`/`RUNNING`.
  The endpoint feels "starved" of workers even though FlashBoot is on
  and global capacity exists. Memory-brain workers may be marked
  "Exited by Runpod" without container logs.
- **Cause:** RunPod's scheduler can only place a worker on a host that
  has enough free disk to satisfy `containerDiskInGb`. Setting this to
  80 GB means the scheduler skips every host that has <80 GB free —
  which is most of the global fleet at any given moment. Setting it to
  30 GB makes the eligible host pool ~3-5× larger.
  The default impulse ("just give it lots of disk to be safe") inverts
  the cost model: every spare GB above what the worker actually needs
  costs you availability, not safety.
- **What `containerDiskInGb` covers (and what it doesn't):**
  MUST fit:
  - `/tmp/*` — including HF cache when FlashBoot misses
    (`HUGGINGFACE_HUB_CACHE=/tmp/hf-cache` fallback path)
  - Process workspaces (`/tmp/<APP>-workspaces`, application logs)
  - vLLM compilation artifacts (~3-5 GB for medium models)
  - HF token / config files (~10 MB)
  Does NOT need to fit:
  - The Docker IMAGE itself (mounted read-only via overlay from the
    host's image cache, separate from the container's writable layer)
  - The model snapshot when FlashBoot HITS (lives at
    `/runpod-volume/huggingface-cache/hub/...`, host-managed mount,
    not counted toward container disk)
  - Anything on `/runpod-volume/*` (separate mount)
- **Right-sizing formula:**
  ```
  containerDiskInGb = model_size_gb           # for cold-start without FlashBoot hit
                    + 5                       # /tmp workspace, logs, app state
                    + (5 if vLLM else 0)      # vLLM compilation cache
                    → round UP to nearest 5
  ```
- **Worked examples (NONNON v8 cutover, 2026-04-25):**
  | Service       | Model on HF | Engine       | OLD disk | NEW disk |
  |---------------|-------------|--------------|---------:|---------:|
  | embedder      |  8.06 GB    | TEI          |    50    |    20    |
  | reranker      |  8.06 GB    | transformers |    40    |    30    |
  | asr           |  4.7 GB     | qwen-asr     |    40    |    35    |
  | tts           |  4.5 GB     | qwen-tts     |    40    |    30    |
  | memory-brain  | 21.9 GB     | vLLM         |    80    |    45    |
  Right-sized values cut scheduler-rejection rates substantially and
  made cold-start spawn-time more reliable.
- **Right-sizing GPU pools (companion lesson):** the same
  over-provisioning logic applies to `gpuIds`. Restricting to 48 GB+
  pools (`AMPERE_48,ADA_48_PRO`) for a 4B-parameter model that fits
  in 12 GB of VRAM excludes the entire 24 GB pool (`ADA_24,AMPERE_24`
  — RTX 4090, A5000, RTX 6000 Ada, etc.) from the scheduler. The
  24 GB pool is ~5-10× larger than the 48 GB pool by host count.
  GPU VRAM budget per service (BF16 weights + 2-3× activation):
  - 1.7B model (ASR/TTS): ~5 GB → fits in 16 GB
  - 4B model (embedder/reranker): ~12-14 GB → fits in 24 GB comfortably
  - 35B-A3B NVFP4 (memory-brain): ~30-40 GB → needs 80 GB+ minimum,
    96 GB+ for headroom
  Pool selection rules:
  - `ADA_24,AMPERE_24,ADA_48_PRO,AMPERE_48` — 4B and smaller models
  - `ADA_48_PRO,AMPERE_48,HOPPER_141` — 7-13B BF16 models
  - `BLACKWELL_96,BLACKWELL_180,HOPPER_141` — NVFP4 W4A4
    (Blackwell-native), or 30B+ BF16
- **Conservative-buffer caveat:** if you set the disk EXACTLY to
  model+workspace, a fresh host with no FlashBoot cache must download
  the full model to `/tmp/hf-cache` while the container is already
  running close to disk-full. If the model is large or the download
  is slow, you risk `ENOSPC` mid-download. The `+5 GB` buffer above
  absorbs this; do NOT skimp on it.
- **Detection:**
  ```bash
  python -c "
  import json, os
  for spec in os.listdir('runpod-serverless-workers/deploy/'):
      if not spec.endswith('.production.json'): continue
      d = json.load(open(f'runpod-serverless-workers/deploy/{spec}'))
      print(f'{spec:40} disk={d[\"containerDiskInGb\"]:3} gpus={d[\"gpuIds\"]}')"
  ```
  Flag any disk value >2× model_size_gb + 10. Flag any spec
  restricted to pools larger than the model's actual VRAM need.
- **Common foot-gun:** the inclination to "give it more headroom to
  be safe" is exactly backwards on serverless. Disk over-provisioning
  shrinks the scheduler's eligible host pool, which DECREASES
  reliability and INCREASES cold-start latency. Right-size aggressively.
- **Reference:** setup-guide §6.1.12.
