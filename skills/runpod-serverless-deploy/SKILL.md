---

## name: runpod-serverless-deploy description: Use when deploying any FastAPI + GPU inference service to RunPod Serverless, setting up GitHub Actions to build a GPU image and push to a LOAD_BALANCER endpoint, or when the target repo has a Dockerfile plus a Hugging Face model revision and a deploy/runpod/\*.json spec.

# RunPod Serverless Deploy

> **Purpose.** Take a working local or pod inference stack (FastAPI + model server) and deliver it as a RunPod Serverless LOAD_BALANCER endpoint. Image-based, immutable, staging-to-production, model served from FlashBoot cache, integrity-gated against answer-injection.

**Skill version:** 2.1.0 (canonical refresh 2026-05-01) **Supersedes:** v2.0.0 (2026-04-23) and `~/.claude/skills/runpod-serverless-deploy/` v1.0.0 **Validated on:** LAMP1 finance-agent-v1.1 (`james47kjv/lamp1`) **Companion:** `runpod-serverless-debug` (triage), `runpod-red-team`(canary + audit).

---

## When to use this skill

Trigger on:

1. "deploy to RunPod Serverless" / "create a serverless endpoint"
2. "ship my model as an API" when the target is RunPod
3. Any repo with `deploy/runpod/*.json` specs with `endpointType: LOAD_BALANCER`
4. "set up GitHub Actions to build a GPU image and push to a RunPod endpoint"
5. "my RunPod worker is stuck in EXITED / throttled / won't boot" — use companion skill `runpod-serverless-debug`
6. "audit the deploy / run the canaries" — use companion skill `runpod-red-team`

Do NOT use for:

- Pod-based training (use `runpod-devops`)
- Non-RunPod platforms (Modal, Replicate, Beam, etc.)
- Local-only inference without a serverless target

---

## The non-negotiable contract

Every deploy using this skill MUST satisfy ALL of these. No exceptions.

 1. **Image-based only.** No `networkVolumeId`, no `startScriptPath` on a volume.

 2. **Immutable image tags.** Format: `ghcr.io/<owner>/<repo>:immutable-<UTC-timestamp>-<short_sha>`. Refuse to overwrite.

 3. **Model via RunPod** `modelReferences` **+** `flashboot: true`**.** Specs may keep local `modelName` as source data, but deploy code must write GraphQL `saveEndpoint.modelReferences` with `HF_TOKEN` present. Weights are NOT baked into the image.

 4. **Staging and production specs.** Differ only in workers and environment label.

 5. **Drift audit** before every production deploy.

 6. **No silent failures in** `start.sh`**.** Every boot stage emits structured JSON.

 7. `GHCR_PAT`**, not** `GITHUB_TOKEN`**,** for GHCR login in CI.

 8. **Integrity gates OFF in production.** The anti-cheating flags (your `<APP>_OFFLINE_FIXTURES` and `<APP>_DETERMINISTIC_OVERRIDES`equivalents) must be unset in any serverless deploy spec. Boot-time `_assert_runtime_integrity()` enforces. LAMP1's specific names shown here are the LAMP1 canon; rename for your app.

 9. **App-layer auth on debug routes.** `Authorization` is consumed by the RunPod gateway; use a custom header (e.g., `X-<APP>-Debug-Token`) for the app-layer defense-in-depth check.

10. `PORT_HEALTH` **MUST be set in env on every LOAD_BALANCER spec**.RunPod's LB poller looks at `PORT_HEALTH` (NOT `PORT`) to find `/ping`. Missing it is the silent killer: the worker boots cleanly, FastAPI serves `/ping` 204/200 internally, the endpoint stays `unhealthy` forever, external `/ping` times out, and there is **no error in any log** because nothing is broken. Set `PORT_HEALTH` to the same value as `PORT` for the standard single-port case. The deploy script must refuse any spec without it. See pitfall #25 / setup-guide §6.1.2.

11. **No region pinning.** No `dataCenterIds`, `locations`, `dataCenterPriority`, `region`, `regionId`, `zoneId`, or `countryCodes` on a serverless endpoint. Endpoints MUST be GLOBAL. The deploy script's `_reject_region_pinning()` must refuse any spec that pins a region. See pitfall #23 / setup-guide §6.1.1.

12. `dockerStartCmd` **MUST be set on every spec.** Format: `["bash", "/app/start.sh"]` (path must match where Dockerfile copies [start.sh](http://start.sh)). RunPod IGNORES the Dockerfile's `CMD` when the base image declares its own — and most modern inference base images do (TEI, TGI, vLLM, NIM, Whisper, faster-whisper, etc.). Without `dockerStartCmd`, the base image's binary runs instead of your `start.sh`, dies in milliseconds with no args, and the worker exits with code 1 and an EMPTY Container logs panel — looks identical to a corrupt image. The deploy script must refuse any spec without it. See pitfall #26 / setup-guide §6.1.3.

13. **Dockerfile MUST set an explicit** `ENTRYPOINT`**, NOT** `[]`.Format: `ENTRYPOINT ["bash", "/app/start.sh"]` and `CMD []`. The empty-array `ENTRYPOINT []` is supposed to clear the inherited entrypoint per the OCI spec, but RunPod's container runtime does not honor it reliably — it falls back to the base image's ENTRYPOINT (a non-trivial setup script on TEI/TGI/vLLM bases that ends in `exec model-server "$@"`) and passes your `dockerStartCmd` as args. Result: model-server runs with "bash /app/start.sh" as the model ID, dies in milliseconds, worker exits code 1 with empty Container logs — even though `dockerStartCmd` is set correctly. Defense in depth: explicit Dockerfile ENTRYPOINT + spec `dockerStartCmd` both pointing at the same script means either one catches what the other misses. See pitfall #27 / setup-guide §6.1.4.

14. **HF cache MUST read from** `/runpod-volume/huggingface-cache/hub`**when present** (RunPod's host-disk cache, populated by endpoint `modelReferences`). Two-tier pattern: read on `/runpod-volume`, write on `/tmp`. Anchoring at `/tmp` defeats FlashBoot — every scale-from-zero re-downloads the model (3-5 min for 7-8 GB models). `/runpod-volume` here is NOT a user-attached Network Volume; it's host-local and does NOT pin region. Spec env MUST NOT hard-code `HF_HOME` or `HUGGINGFACE_HUB_CACHE` — let runtime detection in [start.sh](http://start.sh) / [boot.py](http://boot.py) decide. Diagnostic: emit `hf_cache_resolved` event showing whether `location` is `runpod-host` or `tmp-fallback`, plus `model_cache_hit` for the exact snapshot. See pitfall #30 / setup-guide section 6.1.7.

15. `workersMax` **MUST be at least 3 for armed LOAD_BALANCER endpoints.**`workersMax=1` and `workersMax=2` are scheduler anti-patterns: too few candidate host slots can leave the worker throttled even when global capacity exists. `workersMax` is a cap, not an allocation, so `workersMin=0, workersMax=3` still costs $0 while idle. Use `workersMax=0` only for an explicit hard drain. See pitfall #37 / setup-guide §6.1.14.

16. **Canonical scaler is QUEUE_DELAY @ 4 with idleTimeout=60.** The pre-deploy guards `_require_canonical_scaler()` and `_require_canonical_idle_timeout()` refuse any spec with `REQUEST_COUNT` or `idleTimeout != 60`. The drift monitor at `C:/Users/innas/architecture/scripts/monitoring/runpod_drift_monitor.py` runs every 4 hours via the "RunPod Drift Monitor" Windows scheduled task and auto-heals deviations via REST PATCH. `idleTimeout=60` is the canonical 2026-05-01 value — short enough to keep idle billing minimal on `workersMin=0`, long enough that mid-cold-start "idle" intervals during model load do not cause RunPod's idle reaper to terminate the worker before readiness. See setup-guide v2 §6.1.18 and §6.1.7.2.

17. **All HF repos MUST start with** `james47kjv/`**.** The pre-deploy guard `_require_james47kjv_repo_policy()` refuses any spec that references a non-`james47kjv/*` HF repo via `modelName` or any repo-bearing env var (`NONNON_HF_MODEL_REPO`, `LAMP_HF_MODEL_REPO`, `MODEL_NAME`, `MODEL_ID`, `QWEN3_TTS_MODEL`, `SERVED_MODEL_NAME`, `QWEN3_RERANKER_MODEL_PATH`, `QWEN3_ASR_MODEL_PATH`). See setup-guide v2 §6.1.20.

18. **RunPod Model field verification uses GraphQL** `endpoint.modelReferences`**, not REST** `modelName`**.** REST GET omits `modelName`, so `body.get("modelName") is None` is not proof the UI Model field is empty. Deploy with bare private repo ids, e.g. `james47kjv/nonnon-vl-embedder`, through `saveEndpoint.modelReferences`; RunPod may normalize readback to `https://huggingface.co/<repo>:<revision>`. The pinned revision belongs in template env (`NONNON_HF_MODEL_REVISION`, `LAMP_HF_MODEL_REVISION`, or equivalent). After any model-reference change, run `python C:/Users/innas/architecture/scripts/monitoring/runpod_drift_monitor.py --check`, then verify the next cold boot from container logs: `hf_cache_resolved location=runpod-host` plus `model_cache_hit`. If logs show `tmp-fallback`, `model_cache_miss`, or a live `snapshot_download` path with `NONNON_ALLOW_HF_SELF_HEAL=0`, fix `modelReferences`/cache path instead of raising `workersMin`.

If the user asks you to skip any of these, push back. These are the lessons from the 37 pitfalls catalogued in `REFERENCES/pitfalls-37.md`.

See `REFERENCES/anti-cheating-contract.md` for the full #8 contract.

---

## Core architecture

```
```
POST /v1/chat/completions
  │
```
  ▼ _assert_runtime_integrity() — boot-time gate (refuses boot if gates set)
  ▼ scope_guard                 — fixed refusal for out-of-scope
  ▼ route_question              — family classifier; NO LLM call
  ▼ compile_evidence            ← hits SEC / your data source
  ▼ candidate_bank              — N propose strategies in parallel
  ▼ verifier_bank               — M hard checks; reject any failing candidate
  ▼ critic (P1/P2)              — one LLM pairwise compare
  ▼ arbiter                     — pure scoring; sub-threshold → fixed NIA reply
  ▼ format_repair               — family-specific emitter
  ▼ scrubber                    — leak-marker scrub
  ▼ response + workspace/agent_trace.json + workspace/patterns.jsonl
```

For the full reference architecture see `REFERENCES/harness-guidebook.md §3`and the LAMP1 agent-runtime at `https://github.com/james47kjv/lamp1/tree/main/services/finance-endpoint/agent_runtime.py`.

---

## Quick reference

### Secrets that MUST be present

SecretWhereUsed for`RUNPOD_API_KEY~/.env` + endpoint envRunPod GraphQL + REST + gateway auth`HF_TOKEN~/.env` + endpoint envSelf-heal HF download if FlashBoot misses`GHCR_PAT~/.env` + repo secretGHCR image push in CI`SEC_EDGAR_API_KEY` (or equivalent)`~/.env` + endpoint envEvidence retrieval

**Canonical extraction** (never `source ~/.env`):

```bash
extract() { grep -E "^${1}=" "$HOME/.env" | head -1 | cut -d= -f2; }
export RUNPOD_API_KEY="$(extract RUNPOD_API_KEY)"
export HF_TOKEN="$(extract HF_TOKEN)"
export GHCR_PAT="$(extract GHCR_PAT)"
```

### GPU pool IDs (2026-04 canonical)

- `HOPPER_141` — H200 SXM (141 GB), H200 NVL, H100 NVL, H100 SXM/PCIe
- `BLACKWELL_180` — B200 (180 GB)
- `BLACKWELL_96` — RTX PRO 6000 Server/Workstation/Max-Q (96 GB)
- `AMPERE_80` — A100 80 GB (NOT suitable for NVFP4)
- Plus `AMPERE_16/24/48`, `ADA_24/32_PRO/48_PRO/80_PRO`

**Rule:** Order `gpuIds` with the highest-supply pool first. Check RunPod UI's "Edit Endpoint" for live supply per pool.

### Cold-start measurements (Blackwell, 2026-04-23)

- Warm deterministic: 0.8–2.5 s
- Warm LLM path: 5–25 s
- Cold FlashBoot hit: 263 s (structural floor)
- Cold fresh host: 5–10 min
- First-ever deploy: \~50 min (includes GHA build)
- Outlier: 22-min boot loop if a module is missing from Dockerfile COPY

---

## Templates

`TEMPLATES/` ships 13 starter files. Copy into your repo and parametrize `<APP>`, `<OWNER>`, `<HF_REPO>`, `<HF_REVISION>`:

TemplateTarget pathWhat it is`Dockerfile.templateservices/<app>/Dockerfile`vLLM v0.19.1 base, no weights baked`start.sh.templateservices/<app>/start.sh`Structured-JSON boot; loud-fail`_assert_runtime_integrity.py.templateservices/<app>/app.py` lines \~24-60Boot-time integrity gate`staging.spec.json.templatedeploy/runpod/<app>.staging.jsonworkersMin=0, workersMax=3production.spec.json.templatedeploy/runpod/<app>.production.jsonworkersMin=1, workersMax=3build-image.yml.template.github/workflows/build-image.yml`GHA immutable build + push`ci.yml.template.github/workflows/ci.yml`CPU-only smoke`audit_build_context.py.templatescripts/ci/audit_build_context.py`REQUIRED_PATHS allowlist`deploy_endpoint.py.templatescripts/serverless/deploy_endpoint.py`GraphQL saveEndpoint`redteam_canary.py.templatescripts/serverless/redteam_canary.py`Per-question canary runner`grade_canary.py.templatescripts/serverless/grade_canary.py`Strict lexical grader`autonomous_deploy.sh.templatescripts/serverless/autonomous_deploy.sh`Cost-safe watchdog

---

## Deploy flow (happy path)

CHECKLIST (TodoWrite-ready):

- \[ \] 1. Confirm `~/.env` has `RUNPOD_API_KEY`, `HF_TOKEN`, `GHCR_PAT`, domain-specific keys (`SEC_EDGAR_API_KEY` for finance, etc.).
- \[ \] 2. Copy `TEMPLATES/` into the target repo; parametrize.
- \[ \] 3. Add every new file to `scripts/ci/audit_build_context.py::REQUIRED_PATHS`AND to the Dockerfile `COPY` manifest. Missing either = pitfall 6.
- \[ \] 4. `git push origin main` → `build-image.yml` triggers.
- \[ \] 5. Wait for build: `gh run watch $(gh run list --workflow build-image.yml --limit 1 --json databaseId -q '.[0].databaseId')`.
- \[ \] 6. Grab image tag from release manifest.
- \[ \] 7. Staging deploy: `python scripts/serverless/deploy_endpoint.py --spec deploy/runpod/<app>.staging.json --image <ref> --registry-auth-name ghcr-<app> --registry-username <owner> --registry-password-env GHCR_PAT`.
- \[ \] 8. Warm the worker: `saveEndpoint` with `workersMin=1, workersMax=3`. Poll `/ping` until `{"status":"ready"}`. Budget 15 min.
- \[ \] 9. Canary: `python scripts/serverless/redteam_canary.py --base-url <staging> --api-key $RUNPOD_API_KEY --limit N --out reports/...`
- \[ \] 10. Grade: `python scripts/serverless/grade_canary.py --report-dir <out> --limit N`.
- \[ \] 11. If green, deploy production with the SAME image ref.
- \[ \] 12. Drift audit: `python scripts/serverless/audit_digest.py --endpoint-id <prod_id> --manifest release/manifest.json`.
- \[ \] 13. If prod serves live traffic, keep `workersMin=1`. Otherwise drain: `workersMax=0` on both endpoints. This is the ONLY deterministic off-state (see pitfall 19).

For the full deploy walkthrough see `C:/Users/innas/runpod_serverless_setup_guide_v2.md §8`.

---

## Clean-drain procedure (non-negotiable)

The `REQUEST_COUNT` scaler holds a `workersStandby` target; setting `workersMin=0, workersMax=N (N>0)` does NOT stop the cascade — the scaler keeps spawning replacements as workers drain.

Only `workersMax=0` is deterministic off. The full procedure:

```bash
extract() { grep -E "^${1}=" "$HOME/.env" | head -1 | cut -d= -f2; }
RUNPOD_API_KEY=$(extract RUNPOD_API_KEY)

# 1. Hard-stop (substitute <ENDPOINT_ID>, <NAME>, <TEMPLATE_ID>)
curl -sS https://api.runpod.io/graphql \
  -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
  -d '{"query":"mutation { saveEndpoint(input: { id: \"<ENDPOINT_ID>\", name: \"<NAME>\", templateId: \"<TEMPLATE_ID>\", gpuIds: \"BLACKWELL_96,BLACKWELL_180,HOPPER_141\", gpuCount: 1, workersMin: 0, workersMax: 0, idleTimeout: 60, scalerType: \"QUEUE_DELAY\", scalerValue: 4, type: \"LB\", flashBootType: FLASHBOOT }) { id workersMin workersMax } }"}'

# 2. Poll until workers=0 AND standby=0 (usually <90s)
poll_count() {
  curl -sS --max-time 10 "https://rest.runpod.io/v1/endpoints/$1?includeWorkers=true" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{len(d.get('workers') or [])} {d.get('workersStandby')}\")"
}
until [[ "$(poll_count <ENDPOINT_ID>)" == "0 0" ]]; do sleep 20; done

# 3. NOW restore scale-to-zero-ready state (optional)
# saveEndpoint with workersMin=0, workersMax=3 — future-traffic-ready.
```

**Gotcha:** do NOT include obsolete `modelName` in any RunPod `saveEndpoint` mutation. Use `modelReferences` only for explicit model-reference rollouts; for pure worker/scaler changes use REST PATCH or an update mutation that leaves model fields untouched.

---

## Integrity contract (anti-cheating)

The serverless endpoint MUST NOT have any path that emits a hardcoded answer on a benchmark-matching question. See `REFERENCES/anti-cheating-contract.md` for the full contract. The short form:

1. `<APP>_OFFLINE_FIXTURES` — unset in prod. When unset, precompiled caches + synthetic-evidence fallbacks are unreachable. (LAMP1's name: `LAMP_OFFLINE_FIXTURES`.)
2. `<APP>_DETERMINISTIC_OVERRIDES` — unset in prod. When unset, canned-answer `_qNNN`-style handlers cannot fire. (LAMP1's name: `LAMP_DETERMINISTIC_OVERRIDES`.)
3. `_resolve_q_num` **equivalent** — returns `None` unconditionally in prod. Severs benchmark coupling regardless of question-text match.
4. **Boot-time assertion** — refuses to start staging/prod containers if the required data-access key is unset OR if either gate is enabled.
5. **CI lock** — a test (e.g., `tests/test_integrity_gating.py`) keeps the defaults from drifting back to on.

If a question scores poorly on the benchmark, the fix is NEVER to re-enable a fixture gate or add a new `_qNNN` handler. Fix evidence coverage or candidate quality instead.

---

## Debug-trace route + custom auth header

If your deploy has a `/v1/debug/trace/{workspace_id}` route (to inspect the candidate bank + verifier results + arbiter decision of a specific request), it MUST use defense-in-depth auth:

- **Gateway layer** (RunPod LB): `Authorization: Bearer <RUNPOD_API_KEY>`
- **App layer** (your FastAPI): a CUSTOM header, e.g., `X-<APP>-Debug-Token: <<APP>_DEBUG_TOKEN | RUNPOD_ENDPOINT_SECRET>`

The gateway CONSUMES the `Authorization` header and does NOT forward it raw; using `Authorization` for the app-layer check leaves the route open to anyone with the gateway bearer. `X-Lamp-Debug-Token` passes through the gateway unmodified.

Implementation: `hmac.compare_digest` for constant-time compare. When no secret is configured, return 503 (closed), NOT 200. See `C:/Users/innas/runpod_serverless_setup_guide_v2.md §11.8` for the full code.

---

## Bounded workspace locks

Per-`workspace_id` locking prevents concurrent writes to the same workspace, but naive implementation leaks memory on long-lived workers:

```python
# DON'T
_WORKSPACE_LOCKS: dict[str, threading.Lock] = {}

# DO
_WORKSPACE_LOCKS: dict[str, tuple[threading.Lock, float]] = {}
_WORKSPACE_LOCKS_MAX = 512

def _workspace_lock(workspace_id: str) -> threading.Lock:
    now = time.time()
    with _WORKSPACE_LOCKS_GUARD:
        entry = _WORKSPACE_LOCKS.get(workspace_id)
        if entry is not None:
            lock, _ = entry
            _WORKSPACE_LOCKS[workspace_id] = (lock, now)
            return lock
        # Evict oldest-touched entries when over cap. Only drop
        # entries whose lock is currently unlocked.
        if len(_WORKSPACE_LOCKS) >= _WORKSPACE_LOCKS_MAX:
            victims = sorted(_WORKSPACE_LOCKS.items(), key=lambda kv: kv[1][1])
            for ws_id, (ws_lock, _ts) in victims[: max(1, _WORKSPACE_LOCKS_MAX // 8)]:
                if ws_lock.acquire(blocking=False):
                    try: _WORKSPACE_LOCKS.pop(ws_id, None)
                    finally: ws_lock.release()
        lock = threading.Lock()
        _WORKSPACE_LOCKS[workspace_id] = (lock, now)
        return lock
```

---

## Debugging playbook

When a deploy misbehaves, delegate to the `runpod-serverless-debug` skill or the `runpod-incident-responder`sub-agent. Quick triage:

1. **Worker boots but** `/ping` **times out for &gt;5 min** → likely pitfall 6 (missing Dockerfile COPY). Check `rest.runpod.io/v1/endpoints/<id>?includeWorkers=true` for the worker's `imageName` and correlate to recent commits.
2. **Worker reaches EXITED immediately** → likely pitfall 17 (crash loop in engine). Tail worker log via RunPod dashboard.
3. `workersStandby=1` **but no worker visible** → pitfall 15 (pool unavailable). Reorder `gpuIds`.
4. **UI says** `throttled` **and** `workersMax<=2` → pitfall 37 (`workersMax=1/2` candidate-slot starvation). Set `workersMax=3`. If `workersMax>=3`, then check pitfall 14 (single-SKU pool exhausted).
5. **GHCR push 403** → pitfall 1 (`GITHUB_TOKEN` not allowed).
6. **Actions run fails in 3 s with billing message** → pitfall 7 (account billing). Resolve at [github.com/settings/billing](http://github.com/settings/billing).

See `REFERENCES/pitfalls-37.md` for all 37.

---

## Delegating to a sub-agent

For deep work, delegate to the specialized sub-agent that ships with this plugin:

```
Task(subagent_type="runpod-serverless-expert",
     prompt="Scaffold a RunPod deploy for <describe your service>.")
```

The sub-agent arrives with the full canonical corpus (2,544 lines) loaded as its system context. It will produce Dockerfile + spec + workflow + canary script populated from templates with integrity gates correctly wired.

---

## Codex behavior (cross-agent)

Codex does not have:

- The `Skill` tool — reads this file via `cat` or `Read`.
- `Task` sub-agents — does the work of the expert itself after reading `REFERENCES/*`.
- Slash commands — keyword-triggers via bootstrap text.
- Hooks — no auto-audit; run `audit_digest.py` manually post-deploy.

The bootstrap at `.codex/runpod-codex-bootstrap.md` maps these Claude primitives to Codex-native equivalents.

---

## Pitfalls — the 22 sorted by historical pain

See `REFERENCES/pitfalls-37.md` for symptom/cause/fix on every pitfall. Summary:

#CategoryOne-line1CI`GITHUB_TOKEN` fails GHCR push — use `GHCR_PAT`2EnvMulti-line `.env` value breaks `source` — extract per-key3CICRLF in `start.sh` from Windows — `*.sh text eol=lf`4CIRunner disk exhausts — aggressive cleanup pre-buildx5RegistryOverwriting immutable tag — guard step6**RuntimeNew** `.py` **not in Dockerfile COPY — 22-min boot loop**7CIGitHub Actions billing fails mid-session — settings/billing8RuntimeSilent HF fetch fallback — loud-fail in `start.sh`9Runtime`exit(0)` treated as success — re-raise as 110RuntimeSGLang no FP4 on Hopper — use vLLM v0.19.111RuntimeSGLang Blackwell cudnn crash — use vLLM12RuntimeUnknown `--flag` crashes engine — check `--help`13RunPod`saveEndpoint` needs `gpuIds` — pool ID required14RunPodSingle-SKU pool → throttled — broaden pool15RunPod`workersStandby=1` but no worker — reorder `gpuIds`16RunPodREST drifts from GraphQL — trust GraphQL17RunPod900s probe on crash loop — tail logs independently18RunPodobsolete `modelName` in `saveEndpoint` — use `modelReferences`19**RunPodScaler cascade —** `workersMax=0` **is the only off-state**20SecurityUnbounded `_WORKSPACE_LOCKS` — LRU cap at 51221SecurityGateway consumes `Authorization` — use `X-Lamp-Debug-Token`22Integrity`q_num` benchmark coupling — return `None` unconditionally37**RunPod**`workersMax=1/2` **throttles forever — armed LB endpoints need** `workersMax>=3`

---

## When you finish

1. Commit `release/*-deploy.json` manifests to the repo.
2. Run `audit_digest.py` against the live endpoint and commit `release/drift-audit-<UTC>.json`.
3. If you added a NEW pitfall to the list (23rd), update `REFERENCES/pitfalls-37.md`, bump the skill version, and update the hook + table above.
4. If Graphiti memory is wired, write an episode with: image ref, endpoint IDs, canary pass rate, cold-start observed, any deviations from this skill.
