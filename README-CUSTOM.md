# Personal OpenBot build

Keep `main` identical to `upstream/main`. Make changes on `custom` only. The upstream PolyForm Noncommercial license still applies.

## Development on Windows

Use Node 24 and Bun 1.4.2. Run `bun install --frozen-lockfile` from the checkout. The development entry point is `bun run dev`; do not use `dist:win` or the Windows installer. The default dev profile has its own database but shares the official provider runtime store. Do not launch against the official store. Electron needs an explicit `--user-data-dir` for a self-contained profile.

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
