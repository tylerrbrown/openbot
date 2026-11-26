"""Windows regression: py -3 scripts/dev-updater/swap-e2e.py (needs Bun and repo deps).

Run the real swap, with a synthetic dev launcher and the real AuthService and
D1AuthRepository over the repo's SQLite D1 adapter. Never run the installed
updater, Electron, Wrangler, or Task Scheduler.
"""

import base64
from contextlib import ExitStack, closing
import hashlib
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import uuid


SOURCE = Path(__file__).resolve().parents[2]
AUTH = SOURCE / "apps" / "auth-api"
STATE = Path("apps/auth-api/.wrangler")
DATABASE = Path("state/v3/d1/miniflare-D1DatabaseObject/account.sqlite")
USER_ID = "swap-regression-user"
NOW = 1_800_000_000_000

# bun run dev/dev:stop are the only launcher seams; the updater controls the process lifecycle.
LAUNCHER = r"""
import { DatabaseSync } from 'node:sqlite';
import { appendFileSync, existsSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const config = await Bun.file('fixture.json').json();
const { ports, label, failure, now, instanceId, accountId, authSource, profile, local } = config;
const stop = 'stop-request';
const active = 'active';
if (process.argv[2] === 'stop') {
    if (existsSync(active)) {
        writeFileSync(stop, 'stop');
        for (let i = 0; i < 100 && existsSync(active); i++) await Bun.sleep(50);
        if (existsSync(active)) throw new Error('Fixture did not stop');
    }
    process.exit(0);
}
const restart = existsSync('starts') || label === 'new';
const expectedRestartEnv = { OPENBOT_DEV_READY_TIMEOUT_MS: 180000, OPENBOT_API_PORT: ports.api,
    REMOTE_SIGNAL_PORT: ports.signal, REMOTE_HEALTH_PORT: ports.health, OPENBOT_DEV_RENDERER_PORT: ports.renderer };
if (process.env.OPENBOT_DEV_INSTANCE_ID !== instanceId ||
    process.env.APPDATA !== profile || process.env.LOCALAPPDATA !== local ||
    (await Bun.file(join(profile, `OpenBot Dev ${instanceId}`, 'profile-marker')).text()) !== accountId ||
    restart && Object.entries(expectedRestartEnv).some(([key, value]) => process.env[key] !== String(value))) {
    throw new Error('Fixture did not receive the isolated profile or expected restart timeout');
}
const attempt = existsSync('starts') ? (await Bun.file('starts').text()).trim().split('\n').length + 1 : 1;
appendFileSync('starts', `${attempt}\n`);
const dbPath = join(process.cwd(), config.database);
if (failure === 'changed') {
    const writer = new DatabaseSync(dbPath);
    writer.prepare('UPDATE auth_sessions SET revoked_at = ?').run(now);
    writer.close();
    writeFileSync('apps/auth-api/.wrangler/.openbot-migrate-local-stamp', 'failed-build');
    writeFileSync(join(profile, `OpenBot Dev ${instanceId}`, 'failed-build-marker'), 'changed desktop profile');
    process.exit(9);
}
if (failure === 'unchanged') {
    writeFileSync('apps/auth-api/.wrangler/transient.sqlite-shm', 'new transient data');
    process.exit(9);
}
if ((failure === 'once' && attempt === 1) || (failure === 'rollback-once' && attempt === 2)) process.exit(9);
const fromAuth = (path) => import(pathToFileURL(join(authSource, path)).href);
const { AuthService } = await fromAuth('src/server/auth-service.ts');
const { D1AuthRepository } = await fromAuth('src/server/d1-auth-repository.ts');
const { sqliteD1 } = await fromAuth('scripts/sqlite-d1.ts');
const { Effect } = await import(pathToFileURL(join(authSource, '../../node_modules/effect/dist/index.js')).href);
const db = new DatabaseSync(dbPath, { readOnly: true });
const service = new AuthService({ repository: new D1AuthRepository(sqliteD1(db)), delivery: null, now: () => now });
if (existsSync(stop)) unlinkSync(stop);
const servers = [];
try {
    writeFileSync(active, String(process.pid));
    const ready = () => Response.json({ label });
    servers.push(Bun.serve({ hostname: '127.0.0.1', port: ports.api, async fetch(request) {
        switch (new URL(request.url).pathname) {
            case '/health/live': return ready();
            case '/v1/me': {
                const header = request.headers.get('Authorization');
                const user = header?.startsWith('Bearer ')
                    ? await Effect.runPromise(service.authenticateDesktopSession(header.slice(7))) : null;
                return user ? Response.json({ label, id: user.id }) : new Response(null, { status: 401 });
            }
            default: return new Response(null, { status: 404 });
        }
    }}));
    servers.push(await Bun.listen({ hostname: '127.0.0.1', port: ports.signal, socket: { data() {}, open(connection) { connection.end(); } } }));
    servers.push(Bun.serve({ hostname: '127.0.0.1', port: ports.health, fetch: ready }));
    servers.push(Bun.serve({ hostname: '::1', port: ports.renderer, fetch: ready }));
    for (let i = 0; i < 4800; i++) {
        if (existsSync(stop)) break;
        await Bun.sleep(100);
    }
} finally {
    for (const server of servers) server.stop(true);
    db.close(); // The read-only connection cannot checkpoint the synthetic WAL.
    if (existsSync(`${dbPath}-shm`)) writeFileSync('closed-shm', 'present');
    unlinkSync(active);
}
process.exit(0);
"""

# Run only the swap entry point. Prevent its cleanup hook from touching the live scheduled task.
BOOTSTRAP = r"""
$ErrorActionPreference = 'Stop'
function Unregister-ScheduledTask {
    [CmdletBinding(SupportsShouldProcess)] param([string]$TaskName)
    [IO.File]::WriteAllText($env:OPENBOT_E2E_TASK_MARKER, 'skipped')
}
# Synthetic Electron metadata only for a running harness fixture; no live process enumeration.
function Get-CimInstance {
    [CmdletBinding()] param([string]$ClassName, [string]$Filter)
    if ($ClassName -ne 'Win32_Process') { throw 'Unexpected CIM class in swap' }
    foreach ($treeName in @('old tree', 'new tree')) {
        $tree = Join-Path $env:OPENBOT_E2E_ROOT $treeName
        $active = Join-Path $tree 'active'
        if (-not (Test-Path -LiteralPath $active)) { continue }
        $fixturePid = [int][IO.File]::ReadAllText($active)
        if (-not (Get-Process -Id $fixturePid -ErrorAction SilentlyContinue)) { continue }
        if ($Filter -eq "Name='electron.exe'") {
            [pscustomobject]@{ ProcessId = $fixturePid; ExecutablePath = "$tree\electron.exe";
                CommandLine = "out-dev-app $env:OPENBOT_DEV_INSTANCE_ID" }
        } elseif ($Filter -eq "ParentProcessId=$fixturePid") {
            [pscustomobject]@{ CommandLine = '--type=renderer' }
        }
    }
}
& $env:OPENBOT_E2E_SWAP_SCRIPT -Mode swap
"""


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(command, cwd, env, timeout=25):
    # A dev child can inherit a handle from PowerShell after the swap returns. Do not wait for pipe EOF.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        result = subprocess.run(command, cwd=cwd, env=env, timeout=timeout, creationflags=subprocess.CREATE_NO_WINDOW,
                                stdout=stdout, stderr=stderr)
        stdout.seek(0)
        stderr.seek(0)
        output = stdout.read().decode("utf-8", errors="replace")
        errors = stderr.read().decode("utf-8", errors="replace")
    check(result.returncode == 0, f"{command[0]} exit {result.returncode}:\n{output}{errors}")
    return output.strip()


def alternate_ports():
    with ExitStack() as sockets:
        ports = {}
        for port in ("api", "signal", "health", "renderer"):
            listener = sockets.enter_context(socket.socket(socket.AF_INET6 if port == "renderer" else socket.AF_INET))
            listener.bind(("::1" if port == "renderer" else "127.0.0.1", 0))
            ports[port] = listener.getsockname()[1]
        check(len(set(ports.values())) == 4 and min(ports.values()) >= 49152, "Expected four distinct high ports")
        return ports


def read_session(db, *, immutable=False):
    suffix = "&immutable=1" if immutable else ""
    with closing(sqlite3.connect(db.as_uri() + "?mode=ro" + suffix, uri=True)) as conn:
        return conn.execute("SELECT user_id, revoked_at FROM auth_sessions").fetchall()


def seed_database(path, writer, credential):
    path.parent.mkdir(parents=True)
    with closing(sqlite3.connect(writer)) as conn:
        for migration in sorted((AUTH / "migrations").glob("*.sql")):
            conn.executescript(migration.read_text(encoding="utf-8"))
        check(conn.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal", "Unable to enable WAL")
        conn.execute("PRAGMA wal_autocheckpoint=0")
        conn.execute("INSERT INTO users(id, identity_key, email, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                     (USER_ID, f"email:{USER_ID}", "swap-regression@example.test", NOW, NOW))
        conn.execute("INSERT INTO auth_sessions(id, user_id, token_hash, expires_at, created_at, last_used_at) "
                     "VALUES (?, ?, ?, ?, ?, ?)",
                     ("e2e", USER_ID, base64.urlsafe_b64encode(hashlib.sha256(credential.encode()).digest())
                      .rstrip(b"=").decode("ascii"), NOW + 86_400_000, NOW, NOW))
        conn.commit()
        shutil.copyfile(writer, path)
        shutil.copyfile(str(writer) + "-wal", str(path) + "-wal")
    check(read_session(path, immutable=True) == [], "Seed session must exist only in WAL")
    check(read_session(path) == [(USER_ID, None)], "Seed session is missing from the WAL snapshot")


def request(port, path, credential=None):
    with closing(HTTPConnection("127.0.0.1", port, timeout=1)) as client:
        client.request("GET", path, headers={"Authorization": f"Bearer {credential}"} if credential else {})
        response = client.getresponse()
        body = response.read()
        return response.status, json.loads(body) if body else None


def assert_session(port, credential, label):
    check(request(port, "/v1/me", "invalid") == (401, None), "Auth accepted a bad session")
    check(request(port, "/v1/me", credential) == (200, {"label": label, "id": USER_ID}),
          f"{label} did not authenticate the original session")


def prepare_tree(tree, env, config):
    (tree / "scripts").mkdir(parents=True)
    shutil.copyfile(SOURCE / "scripts/dev-services.ts", tree / "scripts/dev-services.ts")
    (tree / "fixture.json").write_text(json.dumps(config), encoding="utf-8")
    (tree / "fixture.mjs").write_text(LAUNCHER, encoding="utf-8")
    (tree / ".gitignore").write_text(".wrangler/\n/active\n/closed-shm\n/starts\n/stop-request\n", encoding="utf-8")
    (tree / "package.json").write_text(json.dumps({"scripts": {"dev": "bun fixture.mjs", "dev:stop": "bun fixture.mjs stop"}}),
                                       encoding="utf-8")
    run(["git", "init", "--quiet", "--template="], tree, env)
    run(["git", "add", "--all"], tree, env)
    # This commit exists only in the throwaway fixture, not in the source worktree.
    run(["git", "-c", "user.name=Regression Fixture", "-c", "user.email=fixture@example.test",
         "commit", "--quiet", "--no-gpg-sign", "-m", "Synthetic dev fixture"], tree, env)
    return run(["git", "rev-parse", "HEAD"], tree, env)


def wait_for_old(launcher, port):
    for _ in range(100):
        check(launcher.poll() is None, "Old fixture exited before it became healthy")
        try:
            if request(port, "/health/live") == (200, {"label": "old"}):
                return
        except (OSError, TimeoutError):
            pass
        time.sleep(0.1)
    raise RuntimeError("Old fixture did not become healthy")


def scenario(root, failure, bun):
    local, roaming = root / "local", root / "roaming"
    updater = local / "OpenBot" / "updater"
    permanent = local / "OpenBot" / "dev-state" / "auth-api" / ".wrangler"
    instance_id = f"wt-{uuid.uuid4().hex}{uuid.uuid4().hex}"
    credential = uuid.uuid4().hex
    task_marker = root / "scheduled-task-skipped"
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith(("OPENBOT_", "GIT_", "BUN_"))}
    env.update(APPDATA=str(roaming), LOCALAPPDATA=str(local), OPENBOT_DEV_INSTANCE_ID=instance_id,
               OPENBOT_E2E_ROOT=str(root), OPENBOT_E2E_TASK_MARKER=str(task_marker),
               OPENBOT_E2E_SWAP_SCRIPT=str(SOURCE / "scripts/dev-updater/swap.ps1"),
               PATH=str(Path(bun).parent) + os.pathsep + env["PATH"], GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    ports = alternate_ports()
    profile = roaming / f"OpenBot Dev {instance_id}"
    profile.mkdir(parents=True)
    (profile / "profile-marker").write_text(USER_ID, encoding="utf-8")
    updater.mkdir(parents=True)
    old, new = root / "old tree", root / "new tree"
    config = {"ports": ports, "database": str(STATE / DATABASE), "now": NOW, "instanceId": instance_id,
              "accountId": USER_ID, "authSource": str(AUTH), "profile": str(roaming), "local": str(local)}
    old_commit = prepare_tree(old, env, dict(config, label="old", failure="rollback-once" if failure == "changed" else "none"))
    new_commit = prepare_tree(new, env, dict(config, label="new", failure=failure))
    db = old / STATE / DATABASE
    seed_database(db, root / "writer.sqlite", credential)
    (old / STATE / ".openbot-migrate-local-stamp").write_text("original", encoding="utf-8")
    (old / STATE / "transient.sqlite-shm").write_text("initial transient data", encoding="utf-8")
    original_inode = db.stat().st_ino
    (updater / "plan.json").write_text(json.dumps({"oldWorktree": str(old), "newWorktree": str(new),
                                                   "commit": new_commit, "instanceId": instance_id,
                                                   "bun": bun, "ports": ports}), encoding="utf-8")
    (updater / "current.json").write_text(json.dumps({"worktree": str(old), "commit": old_commit,
                                                      "instanceId": instance_id}), encoding="utf-8")
    try:
        with (root / "initial-launch.log").open("wb") as log:
            launcher = subprocess.Popen([bun, "run", "dev"], cwd=old, env=env, stdout=log, stderr=log,
                                        creationflags=subprocess.CREATE_NO_WINDOW)
        wait_for_old(launcher, ports["api"])
        assert_session(ports["api"], credential, "old")
        powershell = Path(env["SYSTEMROOT"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        command = base64.b64encode(BOOTSTRAP.encode("utf-16-le")).decode("ascii")
        run([str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", command],
            root, env, timeout=55)
        launcher.wait(timeout=5)
        result = json.loads((updater / "result.json").read_text(encoding="utf-8-sig"))
        current = json.loads((updater / "current.json").read_text(encoding="utf-8-sig"))
        succeeded = failure in {"none", "once"}
        restored = failure == "changed"
        expected_attempts = 1 if failure == "none" else 2
        label = "new" if succeeded else "old"
        check(result["status"] == ("success" if succeeded else "rolled-back"), f"Unexpected swap status: {result['status']}")
        check(result["attempts"] == expected_attempts, "Incorrect reported start attempts")
        check((new / "starts").read_text().splitlines() == [str(i + 1) for i in range(expected_attempts)],
              "Incorrect observed start attempts")
        rollback_attempts = 0 if succeeded else 2 if restored else 1
        check((old / "starts").read_text().splitlines() == [str(i + 1) for i in range(1 + rollback_attempts)],
              "Incorrect observed rollback attempts")
        if not succeeded:
            check(result["rollbackAttempts"] == rollback_attempts and result["accountRestored"] is restored,
                  "Incorrect rollback or restore report")
        check(current["worktree"] == str(new if succeeded else old) and
              current["commit"] == (new_commit if succeeded else old_commit) and current["instanceId"] == instance_id,
              "Current worktree, commit or instance ID did not match the running build")
        check(task_marker.read_text() == "skipped" and not (updater / "swap.lock").exists(), "Missing task guard or lock cleanup")
        for tree in (old, new):
            check((tree / STATE).is_junction() and (tree / STATE).resolve() == permanent.resolve(), "Incorrect account junction")
        check(((permanent / DATABASE).stat().st_ino != original_inode) is restored, "Incorrect replacement of account file")
        backup = Path(result["backup"])
        check(backup.is_relative_to(local), "Backup is not isolated")
        check((backup / "profile/profile-marker").read_text() == USER_ID, "Profile backup marker missing")
        snapshot = backup / "auth-api" / DATABASE
        if (old / "closed-shm").exists():
            check(snapshot.with_name(snapshot.name + "-shm").is_file(), "Backup omitted the actual SQLite SHM file")
        check((backup / "auth-api/transient.sqlite-shm").read_text() == "initial transient data", "Backup omitted the fixture SHM file")
        check(read_session(snapshot, immutable=True) == [], "Backup does not preserve a WAL-only session")
        check(read_session(snapshot) == [(USER_ID, None)], "Backup cannot read the original session from WAL")
        if failure == "unchanged":
            check((permanent / "transient.sqlite-shm").read_text() == "new transient data", "Only SHM changed; do not restore")
        check((permanent / ".openbot-migrate-local-stamp").read_text() == "original", "Migration stamp was not preserved")
        failed_state = list(permanent.parent.glob(".wrangler.from-failed-build-*"))
        check(len(failed_state) == int(restored), "Incorrect preservation of changed state")
        if restored:
            check(read_session(failed_state[0] / DATABASE) == [(USER_ID, NOW)], "Failed build did not revoke the session")
            check(not (profile / "failed-build-marker").exists(), "Failed build changes survived desktop profile restore")
        assert_session(ports["api"], credential, label)
        print(f"PASS {failure}: {result['status']}; {expected_attempts} new start(s), {rollback_attempts} rollback start(s); "
              f"account restored={restored}; original session accepted", flush=True)
    except Exception:
        for log_path in sorted(updater.glob("*.log")) + [root / "initial-launch.log"]:
            if log_path.exists():
                print(log_path.name, log_path.read_bytes().replace(b"\x00", b"").decode("utf-8-sig", errors="replace"))
        raise
    finally:
        for tree in (old, new):
            run([bun, "run", "dev:stop"], tree, env)
            if (tree / STATE).is_junction():
                (tree / STATE).rmdir()
        if "launcher" in locals():
            launcher.wait(timeout=5)


def main():
    check(os.name == "nt", "Run this test on Windows")
    bun = shutil.which("bun.exe")
    check(bun is not None, "Add Bun to PATH")
    with tempfile.TemporaryDirectory(prefix="openbot-swap-e2e-") as location:
        for failure in ("none", "once", "unchanged", "changed"):
            scenario(Path(location).resolve() / failure, failure, bun)


if __name__ == "__main__":
    main()
