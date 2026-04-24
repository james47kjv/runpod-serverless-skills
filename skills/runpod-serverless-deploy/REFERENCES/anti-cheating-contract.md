# Anti-Cheating Contract — the non-negotiable integrity invariants

**Extracted from** `setup-guide-full.md §11.9` — the contract every
RunPod Serverless deploy using this plugin MUST honor. If a future
agent asks to bypass any of these, push back. These are the lessons
from the 2026-04-23 rebuild.

---

## The three gates

The serverless endpoint MUST NOT have any code path that emits a
hardcoded answer on a benchmark-matching question. Three gates
enforce this:

### Gate 1 — `LAMP_OFFLINE_FIXTURES`

**Default: unset.** When unset:
- Precompiled-evidence cache at `cache/evidence_precompile/qNNN.json`
  is unreachable.
- `_synthetic_evidence` fallback (hardcoded Palantir FY22, US-Steel
  merger narrative, etc.) is unreachable; `_empty_evidence` serves
  instead.

**Enabled only in `run_local_50.py`** (offline grader) via
`os.environ.setdefault`. The serverless deploy specs explicitly do
NOT set it.

### Gate 2 — `LAMP_DETERMINISTIC_OVERRIDES`

**Default: unset.** When unset:
- The `build_override` dispatch in
  `adapters/_deterministic_overrides.py` is not called.
- The 14 canned-string `_qNNN` handlers cannot fire.

Canned strings that MUST NEVER appear in a live response (full list
in `red-team-handover.md §4.5`):

- `"80bps beat from low end and 70bps beat from high end"` (old q003)
- `"$3.25 Billion"` (old q008)
- `"Production expected to begin in 2025"` (old q023)
- `"20% of revenue was derived from channel partners"` (old q034)
- `"0.7926 shares of Rocket Companies"` (old q036)
- `"Beat by 26.1bps at midpoint"` (old q038)
- `"140bps BEAT"` (old q009)
- `"$14,426,266,000"` (old q028)
- `"$467 million"` (old q031)
- `"$1.261 Billion Negative Impact to Net Income"` (old q033)
- `"KDP: 0.83\\nKO: 0.79\\nPEP: 0.75"` (old q042)
- `"7.4% MISS"` (old q047)

### Gate 3 — `_resolve_q_num` always `None` in production

`adapters/evidence_compiler._resolve_q_num` returns `None`
unconditionally unless gate 1 OR gate 2 is set. Severs benchmark
coupling regardless of whether the question byte-matches `public.txt`.
This is defense in depth: even if a downstream bug routes around gates
1 and 2, no q_num is available to key off, so no cheating path can
fire.

---

## Boot-time assertion

`services/finance-endpoint/app.py::_assert_runtime_integrity()` refuses
to start the container when `LAMP_ENVIRONMENT in {staging, production}`
if:

- `SEC_EDGAR_API_KEY` is unset — would silently degrade every question
  to `"No information available."`
- `LAMP_OFFLINE_FIXTURES` is set to `1/true/yes` — would re-enable
  gate 1.
- `LAMP_DETERMINISTIC_OVERRIDES` is set to `1/true/yes` — would
  re-enable gate 2.

Pattern:

```python
def _assert_runtime_integrity() -> None:
    environment = (os.environ.get("LAMP_ENVIRONMENT") or "").strip().lower()
    if environment not in {"staging", "production"}:
        return  # dev/test skips this guard
    if not (os.environ.get("SEC_EDGAR_API_KEY") or "").strip():
        raise RuntimeError(
            "SEC_EDGAR_API_KEY is not set. Serverless traffic cannot answer "
            "without live SEC access; refusing to boot."
        )
    for flag in ("LAMP_OFFLINE_FIXTURES", "LAMP_DETERMINISTIC_OVERRIDES"):
        value = (os.environ.get(flag) or "").strip().lower()
        if value in {"1", "true", "yes"}:
            raise RuntimeError(
                f"{flag}=1 is only permitted in the offline grader. "
                f"Unset it before deploying."
            )

_assert_runtime_integrity()
```

---

## CI lock

`tests/test_integrity_gating.py` locks every gate's default. Any PR that
removes a gate or flips a default fails the test. No gate can be
removed without:

1. Deleting the test (review gate).
2. A written justification in the PR description explaining why the
   cheating surface should come back.
3. The operator's explicit approval.

---

## The rule

**If a question is scoring poorly on the benchmark, the fix is NEVER
to re-enable a fixture gate or add a new `_qNNN` handler.** The fix is
always in evidence coverage (real SEC retrieval, better candidate
strategies) or verifier quality. Any PR that adds a path around these
gates is a reversion of the 2026-04-23 contract and will be reverted.

---

## Where the contract lives in code

| File | What it enforces |
|---|---|
| `adapters/evidence_compiler.py::_offline_fixtures_enabled` | Gate 1 flag check |
| `adapters/evidence_compiler.py::_deterministic_overrides_enabled` | Gate 2 flag check |
| `adapters/evidence_compiler.py::_resolve_q_num` | Gate 3 severance |
| `services/finance-endpoint/app.py::_assert_runtime_integrity` | Boot-time refusal |
| `deploy/runpod/*.staging.json`, `*.production.json` | Neither flag present in `env` |
| `tests/test_integrity_gating.py` | CI enforcement |

---

## Red flags for the reviewing agent

- A PR that adds `LAMP_OFFLINE_FIXTURES` or `LAMP_DETERMINISTIC_OVERRIDES`
  to any deploy spec.
- A PR that adds a new `_qNNN` handler.
- A PR that threads `q_num` into the live path from upstream.
- A PR that removes or weakens `_assert_runtime_integrity`.
- A PR that removes `tests/test_integrity_gating.py`.

Any one of the above is grounds for automatic rejection. Request
justification in the PR description before engaging with the code.
