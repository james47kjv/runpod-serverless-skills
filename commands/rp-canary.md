---
description: Run both canonical canaries (public.txt + synthetic_v1.txt) against a RunPod Serverless endpoint and grade them. Produces a reports/redteam/canary-<UTC>/ directory with per-question JSON, summary, and strict-grader output.
argument-hint: <env:staging|production> [--limit N]
---

# /rp-canary

**Arguments:** `$ARGUMENTS`

Run the LAMP1 dual-canary protocol against a RunPod Serverless endpoint:

1. `public.txt` — 50 Vals-public benchmark questions
2. `synthetic_v1.txt` — 50 held-out synthetic questions

Defaults to `--limit 50`. The user can pass `--limit 5` for a fast smoke.

## Steps

Invoke `runpod-red-team` skill via Skill tool for the full playbook,
then execute:

1. **Parse args.** `$1 = staging|production`. `--limit` default 50.
2. **Verify warm.** `GET /ping` must return `{"status":"ready"}`. If
   not, refuse and tell user to `/rp-warm <env>` first.
3. **Record baseline.** Read worker env via REST to capture image tag.
4. **Run public-50 canary** via
   `scripts/serverless/redteam_canary.py --base-url <URL>
   --api-key $RUNPOD_API_KEY --limit <N> --timeout 300
   --environment <env> --questions-file benchmark_data/data/public.txt
   --out reports/redteam/public-<UTC>`.
5. **Grade public-50** via
   `scripts/serverless/grade_canary.py --report-dir <OUT> --limit <N>
   --out <OUT>/graded.json`.
6. **Run synthetic-50 canary** with
   `--questions-file benchmark_data/data/synthetic_v1.txt
   --out reports/redteam/synthetic-<UTC>`.
7. **Score synthetic-50** via the inline Python from
   `runpod-red-team/SKILL.md` (no gold-answer CSV exists).
8. **Write summary** `reports/redteam/canary-<UTC>/summary.md` with:
   - Image tag under test
   - Public-50 table: substantive / NIA / empty / strict-pass /
     per-family breakdown
   - Synthetic-50 table: substantive / NIA / leaks / refusals
   - Comparison to the 2026-04-23 baseline
   - Top 3 recommended fixes ranked by expected score impact

## Anti-cheating spot-check (always run)

Even on a small `--limit`, always fire 5 byte-exact `public.txt` lines
(q003, q008, q023, q038, q047) and check for the canned-string patterns
from `anti-cheating-contract.md`. Any match = CRITICAL; include at the
top of the summary.

## Guardrails

- Refuse if env is not `staging|production`.
- Cost note if `--limit 50` (~$0.50 warm).
- If production has `workersMin=0`, refuse — production should be warm
  for a canary run (cold-start would skew the first 1-2 answers).
