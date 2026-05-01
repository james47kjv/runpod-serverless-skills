**Arguments:** `$ARGUMENTS`

Pin the endpoint's workers to `min=1, max=3` and poll `/ping` with visible progress until `{"status":"ready"}` or 15-minute timeout.

## Steps

1. **Parse arg.** `staging` / `production`. No default — always explicit.

2. **Read endpoint config.** ID, name, templateId from `deploy/runpod/<app>.<env>.json`.

3. **Execute** `saveEndpoint` with `workersMin=1, workersMax=3` (NEVER `workersMax=1` — pitfall #37 throttle antipattern; cost is unchanged because `workersMax` is a cap, not an allocation), `gpuIds: "BLACKWELL_96,BLACKWELL_180,HOPPER_141"`.

4. **Poll** `/ping` every 15s, showing elapsed time:

   ```
   
   ```
   [15s]  ping=err (still cold)
   [30s]  ping=err (still cold)
   [165s] ping={"status":"ready"}
   === READY at 165s ===
   ```

5. **If not ready by 15 min:** report endpoint state (worker `desiredStatus`, last-start timestamp, workersStandby), suggest running `/rp-drain <env>` + wait + try again, OR invoke
