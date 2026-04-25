---
name: runpod-serverless-deploy
description: Use when deploying any FastAPI + GPU inference service to RunPod Serverless, setting up GitHub Actions to build a GPU image and push to a LOAD_BALANCER endpoint, or when the target repo has a Dockerfile plus a Hugging Face model revision and a deploy/runpod/*.json spec.
---

# RunPod Serverless Deploy

> **Purpose.** Take a working local or pod inference stack (FastAPI +
> model server) and deliver it as a RunPod Serverless LOAD_BALANCER
> endpoint. Image-based, immutable, staging-to-production, model served
> from FlashBoot cache, integrity-gated against answer-injection.

**Skill version:** 2.0.0 (refreshed 2026-04-23)
**Supersedes:** `~/.claude/skills/runpod-serverless-deploy/` v1.0.0
**Validated on:** LAMP1 finance-agent-v1.1 (`james47kjv/lamp1`)
**Companion:** `runpod-serverless-debug` (triage), `runpod-red-team`
(canary + audit).

---

## When to use this skill

Trigger on:

1. "deploy to RunPod Serverless" / "create a serverless endpoint"
2. "ship my model as an API" when the target is RunPod
3. Any repo with `deploy/runpod/*.json` specs with
   `endpointType: LOAD_BALANCER`
4. "set up GitHub Actions to build a GPU image and push to a RunPod endpoint"
5. "my RunPod worker is stuck in EXITED / throttled / won't boot" —
   use companion skill `runpod-serverless-debug`
6. "audit the deploy / run the canaries" — use companion skill
   `runpod-red-team`

Do NOT use for:

- Pod-based training (use `runpod-devops`)
- Non-RunPod platforms (Modal, Replicate, Beam, etc.)
- Local-only inference without a serverless target

---

## The non-negotiable contract

Every deploy using this skill MUST satisfy ALL of these. No exceptions.

1. **Image-based only.** No `networkVolumeId`, no `startScriptPath` on
   a volume.
2. **Immutable image tags.** Format:
   `ghcr.io/<owner>/<repo>:immutable-<UTC-timestamp>-<short_sha>`.
   Refuse to overwrite.
3. **Model via `modelName` + `flashboot: true`.** Weights NOT baked
   into image.
4. **Staging and production specs.** Differ only in workers and
   environment label.
5. **Drift audit** before every production deploy.
6. **No silent failures in `start.sh`.** Every boot stage emits
   structured JSON.
7. **`GHCR_PAT`, not `GITHUB_TOKEN`,** for GHCR login in CI.
8. **Integrity gates OFF in production.** The anti-cheating flags
   (your `<APP>_OFFLINE_FIXTURES` and `<APP>_DETERMINISTIC_OVERRIDES`
   equivalents) must be unset in any serverless deploy spec. Boot-time
   `_assert_runtime_integrity()` enforces. LAMP1's specific names shown
   here are the LAMP1 canon; rename for your app.
9. **App-layer auth on debug routes.** `Authorization` is consumed by
   the RunPod gateway; use a custom header (e.g.,
   `X-<APP>-Debug-Token`) for the app-layer defense-in-depth check.
10. **`PORT_HEALTH` MUST be set in env on every LOAD_BALANCER spec.**
    RunPod's LB poller looks at `PORT_HEALTH` (NOT `PORT`) to find
    `/ping`. Missing it is the silent killer: the worker boots
    cleanly, FastAPI serves `/ping` 204/200 internally, the endpoint
    stays `unhealthy` forever, external `/ping` times out, and there
    is **no error in any log** because nothing is broken. Set
    `PORT_HEALTH` to the same value as `PORT` for the standard
    single-port case. The deploy script must refuse any spec without
    it. See pitfall #25 / setup-guide §6.1.2.
11. **No region pinning.** No `dataCenterIds`, `locations`,
    `dataCenterPriority`, `region`, `regionId`, `zoneId`, or
    `countryCodes` on a serverless endpoint. Endpoints MUST be
    GLOBAL. The deploy script's `_reject_region_pinning()` must
    refuse any spec that pins a region. See pitfall #23 /
    setup-guide §6.1.1.
12. **`dockerStartCmd` MUST be set on every spec.** Format:
    `["bash", "/app/start.sh"]` (path must match where Dockerfile
    copies start.sh). RunPod IGNORES the Dockerfile's `CMD` when
    the base image declares its own — and most modern inference
    base images do (TEI, TGI, vLLM, NIM, Whisper, faster-whisper,
    etc.). Without `dockerStartCmd`, the base image's binary runs
    instead of your `start.sh`, dies in milliseconds with no args,
    and the worker exits with code 1 and an EMPTY Container logs
    panel — looks identical to a corrupt image. The deploy script
    must refuse any spec without it. See pitfall #26 / setup-guide
    §6.1.3.
13. **Dockerfile MUST set an explicit `ENTRYPOINT`, NOT `[]`.**
    Format: `ENTRYPOINT ["bash", "/app/start.sh"]` and `CMD []`.
    The empty-array `ENTRYPOINT []` is supposed to clear the
    inherited entrypoint per the OCI spec, but RunPod's container
    runtime does not honor it reliably — it falls back to the base
    image's ENTRYPOINT (a non-trivial setup script on TEI/TGI/vLLM
    bases that ends in `exec model-server "$@"`) and passes your
    `dockerStartCmd` as args. Result: model-server runs with
    "bash /app/start.sh" as the model ID, dies in milliseconds,
    worker exits code 1 with empty Container logs — even though
    `dockerStartCmd` is set correctly. Defense in depth: explicit
    Dockerfile ENTRYPOINT + spec `dockerStartCmd` both pointing at
    the same script means either one catches what the other misses.
    See pitfall #27 / setup-guide §6.1.4.

14. **HF cache MUST read from `/runpod-volume/huggingface-cache/hub`
    when present** (RunPod's host-disk cache, populated by
    `spec.modelName`). Two-tier pattern: read on `/runpod-volume`,
    write on `/tmp`. Anchoring at `/tmp` defeats FlashBoot — every
    scale-from-zero re-downloads the model (3-5 min for 7-8 GB
    models). `/runpod-volume` here is NOT a user-attached Network
    Volume; it's host-local and does NOT pin region. Spec env MUST
    NOT hard-code `HF_HOME` or `HUGGINGFACE_HUB_CACHE` — let
    runtime detection in start.sh / boot.py decide. Diagnostic:
    emit `hf_cache_resolved` event showing whether `location` is
    `runpod-host` or `tmp-fallback`. See pitfall #30 / setup-guide
    section 6.1.7.

If the user asks you to skip any of these, push back. These are the
lessons from the 35 pitfalls catalogued in `REFERENCES/pitfalls-35.md`.

See `REFERENCES/anti-cheating-contract.md` for the full #8 contract.

---

## Core architecture

```
POST /v1/chat/completions
  │
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

For the full reference architecture see `REFERENCES/harness-guidebook.md §3`
and the LAMP1 agent-runtime at
`https://github.com/james47kjv/lamp1/tree/main/services/finance-endpoint/agent_runtime.py`.

---

## Quick reference

### Secrets that MUST be present

| Secret | Where | Used for |
|---|---|---|
| `RUNPOD_API_KEY` | `~/.env` + endpoint env | RunPod GraphQL + REST + gateway auth |
| `HF_TOKEN` | `~/.env` + endpoint env | Self-heal HF download if FlashBoot misses |
| `GHCR_PAT` | `~/.env` + repo secret | GHCR image push in CI |
| `SEC_EDGAR_API_KEY` (or equivalent) | `~/.env` + endpoint env | Evidence retrieval |

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

**Rule:** Order `gpuIds` with the highest-supply pool first. Check
RunPod UI's "Edit Endpoint" for live supply per pool.

### Cold-start measurements (Blackwell, 2026-04-23)

- Warm deterministic: 0.8–2.5 s
- Warm LLM path: 5–25 s
- Cold FlashBoot hit: 263 s (structural floor)
- Cold fresh host: 5–10 min
- First-ever deploy: ~50 min (includes GHA build)
- Outlier: 22-min boot loop if a module is missing from Dockerfile COPY

---

## Templates

`TEMPLATES/` ships 13 starter files. Copy into your repo and
parametrize `<APP>`, `<OWNER>`, `<HF_REPO>`, `<HF_REVISION>`:

| Template | Target path | What it is |
|---|---|---|
| `Dockerfile.template` | `services/<app>/Dockerfile` | vLLM v0.19.1 base, no weights baked |
| `start.sh.template` | `services/<app>/start.sh` | Structured-JSON boot; loud-fail |
| `_assert_runtime_integrity.py.template` | `services/<app>/app.py` lines ~24-60 | Boot-time integrity gate |
| `staging.spec.json.template` | `deploy/runpod/<app>.staging.json` | `workersMin=0, workersMax=1` |
| `production.spec.json.template` | `deploy/runpod/<app>.production.json` | `workersMin=1, workersMax=2` |
| `build-image.yml.template` | `.github/workflows/build-image.yml` | GHA immutable build + push |
| `ci.yml.template` | `.github/workflows/ci.yml` | CPU-only smoke |
| `audit_build_context.py.template` | `scripts/ci/audit_build_context.py` | REQUIRED_PATHS allowlist |
| `deploy_endpoint.py.template` | `scripts/serverless/deploy_endpoint.py` | GraphQL saveEndpoint |
| `redteam_canary.py.template` | `scripts/serverless/redteam_canary.py` | Per-question canary runner |
| `grade_canary.py.template` | `scripts/serverless/grade_canary.py` | Strict lexical grader |
| `autonomous_deploy.sh.template` | `scripts/serverless/autonomous_deploy.sh` | Cost-safe watchdog |

---

## Deploy flow (happy path)

CHECKLIST (TodoWrite-ready):

- [ ] 1. Confirm `~/.env` has `RUNPOD_API_KEY`, `HF_TOKEN`, `GHCR_PAT`,
      domain-specific keys (`SEC_EDGAR_API_KEY` for finance, etc.).
- [ ] 2. Copy `TEMPLATES/` into the target repo; parametrize.
- [ ] 3. Add every new file to `scripts/ci/audit_build_context.py::REQUIRED_PATHS`
      AND to the Dockerfile `COPY` manifest. Missing either = pitfall 6.
- [ ] 4. `git push origin main` → `build-image.yml` triggers.
- [ ] 5. Wait for build:
      `gh run watch $(gh run list --workflow build-image.yml --limit 1 --json databaseId -q '.[0].databaseId')`.
- [ ] 6. Grab image tag from release manifest.
- [ ] 7. Staging deploy:
      `python scripts/serverless/deploy_endpoint.py --spec deploy/runpod/<app>.staging.json --image <ref> --registry-auth-name ghcr-<app> --registry-username <owner> --registry-password-env GHCR_PAT`.
- [ ] 8. Warm the worker: `saveEndpoint` with `workersMin=1, workersMax=1`.
      Poll `/ping` until `{"status":"ready"}`. Budget 15 min.
- [ ] 9. Canary: `python scripts/serverless/redteam_canary.py --base-url <staging> --api-key $RUNPOD_API_KEY --limit N --out reports/...`
- [ ] 10. Grade: `python scripts/serverless/grade_canary.py --report-dir <out> --limit N`.
- [ ] 11. If green, deploy production with the SAME image ref.
- [ ] 12. Drift audit: `python scripts/serverless/audit_digest.py --endpoint-id <prod_id> --manifest release/manifest.json`.
- [ ] 13. If prod serves live traffic, keep `workersMin=1`. Otherwise
      drain: `workersMax=0` on both endpoints. This is the ONLY
      deterministic off-state (see pitfall 19).

For the full deploy walkthrough see `C:/Users/innas/runpod_serverless_setup_guide.md §8`.

---

## Clean-drain procedure (non-negotiable)

The `REQUEST_COUNT` scaler holds a `workersStandby` target; setting
`workersMin=0, workersMax=N (N>0)` does NOT stop the cascade — the
scaler keeps spawning replacements as workers drain.

Only `workersMax=0` is deterministic off. The full procedure:

```bash
extract() { grep -E "^${1}=" "$HOME/.env" | head -1 | cut -d= -f2; }
RUNPOD_API_KEY=$(extract RUNPOD_API_KEY)

# 1. Hard-stop (substitute <ENDPOINT_ID>, <NAME>, <TEMPLATE_ID>)
curl -sS https://api.runpod.io/graphql \
  -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
  -d '{"query":"mutation { saveEndpoint(input: { id: \"<ENDPOINT_ID>\", name: \"<NAME>\", templateId: \"<TEMPLATE_ID>\", gpuIds: \"BLACKWELL_96,BLACKWELL_180,HOPPER_141\", gpuCount: 1, workersMin: 0, workersMax: 0, idleTimeout: 300, scalerType: \"REQUEST_COUNT\", scalerValue: 1, type: \"LB\", flashBootType: FLASHBOOT }) { id workersMin workersMax } }"}'

# 2. Poll until workers=0 AND standby=0 (usually <90s)
poll_count() {
  curl -sS --max-time 10 "https://rest.runpod.io/v1/endpoints/$1?includeWorkers=true" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{len(d.get('workers') or [])} {d.get('workersStandby')}\")"
}
until [[ "$(poll_count <ENDPOINT_ID>)" == "0 0" ]]; do sleep 20; done

# 3. NOW restore scale-to-zero-ready state (optional)
# saveEndpoint with workersMin=0, workersMax=1 — future-traffic-ready.
```

**Gotcha:** do NOT include `modelName` in an update-only `saveEndpoint`
mutation. Set it once at create time via `deploy_endpoint.py`; including
it mid-rollout causes 500 (pitfall 18).

---

## Integrity contract (anti-cheating)

The serverless endpoint MUST NOT have any path that emits a hardcoded
answer on a benchmark-matching question. See
`REFERENCES/anti-cheating-contract.md` for the full contract. The
short form:

1. **`<APP>_OFFLINE_FIXTURES`** — unset in prod. When unset, precompiled
   caches + synthetic-evidence fallbacks are unreachable. (LAMP1's
   name: `LAMP_OFFLINE_FIXTURES`.)
2. **`<APP>_DETERMINISTIC_OVERRIDES`** — unset in prod. When unset,
   canned-answer `_qNNN`-style handlers cannot fire. (LAMP1's name:
   `LAMP_DETERMINISTIC_OVERRIDES`.)
3. **`_resolve_q_num` equivalent** — returns `None` unconditionally in
   prod. Severs benchmark coupling regardless of question-text match.
4. **Boot-time assertion** — refuses to start staging/prod containers
   if the required data-access key is unset OR if either gate is enabled.
5. **CI lock** — a test (e.g., `tests/test_integrity_gating.py`) keeps
   the defaults from drifting back to on.

If a question scores poorly on the benchmark, the fix is NEVER to
re-enable a fixture gate or add a new `_qNNN` handler. Fix evidence
coverage or candidate quality instead.

---

## Debug-trace route + custom auth header

If your deploy has a `/v1/debug/trace/{workspace_id}` route (to inspect
the candidate bank + verifier results + arbiter decision of a specific
request), it MUST use defense-in-depth auth:

- **Gateway layer** (RunPod LB): `Authorization: Bearer <RUNPOD_API_KEY>`
- **App layer** (your FastAPI): a CUSTOM header, e.g.,
  `X-<APP>-Debug-Token: <<APP>_DEBUG_TOKEN | RUNPOD_ENDPOINT_SECRET>`

The gateway CONSUMES the `Authorization` header and does NOT forward it
raw; using `Authorization` for the app-layer check leaves the route
open to anyone with the gateway bearer. `X-Lamp-Debug-Token` passes
through the gateway unmodified.

Implementation: `hmac.compare_digest` for constant-time compare. When
no secret is configured, return 503 (closed), NOT 200. See
`C:/Users/innas/runpod_serverless_setup_guide.md §11.8` for the full code.

---

## Bounded workspace locks

Per-`workspace_id` locking prevents concurrent writes to the same
workspace, but naive implementation leaks memory on long-lived workers:

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

When a deploy misbehaves, delegate to the
`runpod-serverless-debug` skill or the `runpod-incident-responder`
sub-agent. Quick triage:

1. **Worker boots but `/ping` times out for >5 min** → likely pitfall
   6 (missing Dockerfile COPY). Check
   `rest.runpod.io/v1/endpoints/<id>?includeWorkers=true` for the
   worker's `imageName` and correlate to recent commits.
2. **Worker reaches EXITED immediately** → likely pitfall 17 (crash
   loop in engine). Tail worker log via RunPod dashboard.
3. **`workersStandby=1` but no worker visible** → pitfall 15 (pool
   unavailable). Reorder `gpuIds`.
4. **UI says `throttled`** → pitfall 14 (single-SKU pool exhausted).
   Broaden `gpuTypeIds` or add a pool.
5. **GHCR push 403** → pitfall 1 (`GITHUB_TOKEN` not allowed).
6. **Actions run fails in 3 s with billing message** → pitfall 7
   (account billing). Resolve at github.com/settings/billing.

See `REFERENCES/pitfalls-35.md` for all 22.

---

## Delegating to a sub-agent

For deep work, delegate to the specialized sub-agent that ships with
this plugin:

```
Task(subagent_type="runpod-serverless-expert",
     prompt="Scaffold a RunPod deploy for <describe your service>.")
```

The sub-agent arrives with the full canonical corpus (2,544 lines)
loaded as its system context. It will produce Dockerfile + spec +
workflow + canary script populated from templates with integrity gates
correctly wired.

---

## Codex behavior (cross-agent)

Codex does not have:
- The `Skill` tool — reads this file via `cat` or `Read`.
- `Task` sub-agents — does the work of the expert itself after reading
  `REFERENCES/*`.
- Slash commands — keyword-triggers via bootstrap text.
- Hooks — no auto-audit; run `audit_digest.py` manually post-deploy.

The bootstrap at `.codex/runpod-codex-bootstrap.md` maps these Claude
primitives to Codex-native equivalents.

---

## Pitfalls — the 22 sorted by historical pain

See `REFERENCES/pitfalls-35.md` for symptom/cause/fix on every pitfall.
Summary:

| # | Category | One-line |
|---|---|---|
| 1 | CI | `GITHUB_TOKEN` fails GHCR push — use `GHCR_PAT` |
| 2 | Env | Multi-line `.env` value breaks `source` — extract per-key |
| 3 | CI | CRLF in `start.sh` from Windows — `*.sh text eol=lf` |
| 4 | CI | Runner disk exhausts — aggressive cleanup pre-buildx |
| 5 | Registry | Overwriting immutable tag — guard step |
| 6 | **Runtime** | **New `.py` not in Dockerfile COPY — 22-min boot loop** |
| 7 | CI | GitHub Actions billing fails mid-session — settings/billing |
| 8 | Runtime | Silent HF fetch fallback — loud-fail in `start.sh` |
| 9 | Runtime | `exit(0)` treated as success — re-raise as 1 |
| 10 | Runtime | SGLang no FP4 on Hopper — use vLLM v0.19.1 |
| 11 | Runtime | SGLang Blackwell cudnn crash — use vLLM |
| 12 | Runtime | Unknown `--flag` crashes engine — check `--help` |
| 13 | RunPod | `saveEndpoint` needs `gpuIds` — pool ID required |
| 14 | RunPod | Single-SKU pool → throttled — broaden pool |
| 15 | RunPod | `workersStandby=1` but no worker — reorder `gpuIds` |
| 16 | RunPod | REST drifts from GraphQL — trust GraphQL |
| 17 | RunPod | 900s probe on crash loop — tail logs independently |
| 18 | RunPod | `saveEndpoint` 500 with `modelName` mid-rollout — omit it |
| 19 | **RunPod** | **Scaler cascade — `workersMax=0` is the only off-state** |
| 20 | Security | Unbounded `_WORKSPACE_LOCKS` — LRU cap at 512 |
| 21 | Security | Gateway consumes `Authorization` — use `X-Lamp-Debug-Token` |
| 22 | Integrity | `q_num` benchmark coupling — return `None` unconditionally |

---

## When you finish

1. Commit `release/*-deploy.json` manifests to the repo.
2. Run `audit_digest.py` against the live endpoint and commit
   `release/drift-audit-<UTC>.json`.
3. If you added a NEW pitfall to the list (23rd), update
   `REFERENCES/pitfalls-35.md`, bump the skill version, and update
   the hook + table above.
4. If Graphiti memory is wired, write an episode with: image ref,
   endpoint IDs, canary pass rate, cold-start observed, any deviations
   from this skill.
