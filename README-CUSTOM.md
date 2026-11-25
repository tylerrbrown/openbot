# Personal OpenBot build

Keep `main` identical to `upstream/main`. Make changes on `custom` only. The upstream PolyForm Noncommercial license still applies.

## Development on Windows

Use Node 24 and Bun 1.4.2. Run `bun install --frozen-lockfile` from the checkout. The development entry point is `bun run dev`; do not use `dist:win` or the Windows installer. The dev launcher passes the checkout’s dev profile to Electron with `--user-data-dir`. The dev database and provider runtimes stay in that profile, separate from the installed app.

For the changes to check after each upstream update, see [patches.md](patches.md).

## Sync with upstream

Start with a clean working tree. Run one line at a time and stop on any error. If the fast-forward fails, inspect the divergence rather than resetting `main`. If rebase reports a conflict, resolve and review it before publishing.

```sh
git fetch upstream
git checkout main
git merge --ff-only upstream/main
git push origin main
git checkout custom
git rebase main
git push --force-with-lease origin custom
```

The last command rewrites the fork's `custom` history. If the lease fails, inspect the remote changes; do not replace it with `--force`.

## Update the dev build from inside OpenBot

The updater scripts live in `scripts/dev-updater/`. Prep can run while the app is open. The swap runs from a one-time scheduled task so it is not a child of OpenBot. Account state is kept in `%LOCALAPPDATA%\OpenBot\dev-state\auth-api\.wrangler`, and each worktree's `apps/auth-api/.wrangler` is a junction to that folder. The running app is not stopped by prep, by a dry run, or by launching `swap.ps1` with no arguments.

Use the `update-openbot-dev` skill. It runs prep, schedules the swap, and reads `%LOCALAPPDATA%\OpenBot\updater\result.json` after the restart.
