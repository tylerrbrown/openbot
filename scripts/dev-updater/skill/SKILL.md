---
name: update-openbot-dev
description: Prepare an upstream update of Tyler's OpenBot Dev build. Schedule the restart that swaps worktrees only when Tyler explicitly authorizes a live swap.
example-prompt: Update my OpenBot dev build
---

# Update the OpenBot dev build

Prep runs while OpenBot is open. **Do not run or schedule a live swap until Tyler explicitly says to do so.** When authorized, let the scheduled task restart OpenBot; running the swap inside OpenBot interrupts the agent that started it.

The installed scripts are:

- `%LOCALAPPDATA%\OpenBot\updater\prep.ps1`
- `%LOCALAPPDATA%\OpenBot\updater\swap.ps1`

The repo copies are `scripts/dev-updater/`. Prefer the installed copies. They are the ones the scheduled task runs.

## Steps

1. Run prep. Do not stop the app yourself.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OpenBot\updater\prep.ps1" -Mode run
```

2. Read `%LOCALAPPDATA%\OpenBot\updater\plan.json` and `%LOCALAPPDATA%\OpenBot\updater\prep.log`. Confirm the plan came from the current successful prep. If `plan.json` is left over from an older failed run, run prep first. Never register against a stale plan. If prep fails, report the error and stop; do not schedule a swap.

3. Confirm Tyler has authorized the live swap. Tell him OpenBot will restart and that a cold start or retry can take several minutes.

4. Register the swap only with Tyler's authorization and a fresh plan. Do not pass `-Mode swap`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OpenBot\updater\swap.ps1" -Mode register
```

5. Read `%LOCALAPPDATA%\OpenBot\updater\result.json` and report the outcome. `success` means the new worktree is current. `rolled-back` means the previous build became healthy. If rollback fails both starts, follow the recovery instructions in `result.json` and leave the database alone. Do not attempt another restore or swap on your own.

## Startup, backup, and rollback

- `OPENBOT_DEV_READY_TIMEOUT_MS` defaults to `180000` (180 seconds) for each of the Auth API and Signal readiness checks. Prep reapplies this patch if the upstream merge drops it. Swap sets it for both the new and previous builds.
- If a build fails its startup health check, swap runs `dev:stop`, verifies the ports are free, and retries that build once. This also applies to the previous build during rollback.
- Swap backs up the profile and the entire `.wrangler` account folder only after a confirmed stop and after the Auth API, Signal, Signal health, and renderer ports are free. It verifies file count and sizes, including SQLite `-wal` and `-shm` files.
- Rollback restores the entire account folder only if the database, write-ahead log, or migration stamp changed. A change to the temporary `-shm` index alone does not trigger a restore. Never restore individual SQLite files.

Launching `swap.ps1` with no arguments is a dry run. It does not stop the app.
