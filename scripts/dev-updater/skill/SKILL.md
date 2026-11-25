---
name: update-openbot-dev
description: Prepare an upstream update of Tyler's OpenBot Dev build, then schedule the restart that swaps worktrees without dropping the local account. Use when Tyler asks to update OpenBot, pull upstream, or restart the dev build onto a prepared worktree.
example-prompt: Update my OpenBot dev build
---

# Update the OpenBot dev build

Prep runs while OpenBot is open. The swap does not. Running the swap inside OpenBot stops the app and kills the agent that started it. Schedule the swap, then let the task restart OpenBot.

The installed scripts are:

- `%LOCALAPPDATA%\OpenBot\updater\prep.ps1`
- `%LOCALAPPDATA%\OpenBot\updater\swap.ps1`

The repo copies are `scripts/dev-updater/`. Prefer the installed copies. They are the ones the scheduled task runs.

## Steps

1. Run prep. Do not stop the app yourself.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OpenBot\updater\prep.ps1" -Mode run
```

2. Read `%LOCALAPPDATA%\OpenBot\updater\plan.json` and `%LOCALAPPDATA%\OpenBot\updater\prep.log`. If prep failed, tell Tyler the error and stop. Do not schedule a swap. A failed prep leaves the live app where it was.

3. Tell Tyler that OpenBot will restart for about a minute.

4. Schedule the swap. Do not pass `-Mode swap`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OpenBot\updater\swap.ps1" -Mode register
```

5. After OpenBot is back, read `%LOCALAPPDATA%\OpenBot\updater\result.json` and report it. `success` means the new worktree is current. `rolled-back` means the previous worktree was started again. `failed` means the rollback did not become healthy, and the backup path in the result is the copy to use.

Launching `swap.ps1` with no arguments is a dry run. It does not stop the app.
