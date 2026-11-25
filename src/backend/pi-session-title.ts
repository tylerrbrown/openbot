import { execFile } from "node:child_process";
import { open } from "node:fs/promises";
import { hostname } from "node:os";
import { isAbsolute, join } from "node:path";
import { Effect } from "effect";
import { getString } from "./protocol";
import { providerCall, providerFailure } from "./provider-client-effects";

export const personalPiNaming = () =>
  process.platform === "win32" && hostname().toLowerCase() === "min" && Boolean(process.env.CLAUDE_HOME);

export const startedByOpenBot = (path: string) =>
  providerCall(async () => {
    const handle = await open(path, "r");
    try {
      const buffer = Buffer.alloc(65536);
      const { bytesRead } = await handle.read(buffer);
      for (const line of buffer.toString("utf8", 0, bytesRead).split("\n").slice(0, -1)) {
        const entry = JSON.parse(line);
        if (getString(entry, "type") === "message") return false;
        if (
          getString(entry, "type") === "custom" &&
          getString(entry, "customType") === "openbot.launch-source" &&
          getString(entry, "data") === "openbot"
        )
          return true;
      }
      return false;
    } finally {
      await handle.close();
    }
  });

export const piSessionTitle = Effect.fn("Pi.sessionTitle")(function* (topic: string, cwd: string) {
  const home = process.env.CLAUDE_HOME;
  const appData = process.env.LOCALAPPDATA;
  if (!personalPiNaming() || !home || !isAbsolute(home) || !appData || !isAbsolute(appData)) return null;
  const output = yield* Effect.tryPromise({
    try: (signal) =>
      new Promise<string>((resolve, reject) => {
        const child = execFile(
          join(appData, "Programs", "Python", "Launcher", "py.exe"),
          [
            "-3",
            "-X",
            "utf8",
            join(home, ".claude", "skills", "sessions", "scripts", "sessions_cli.py"),
            "name",
            "--json",
            "--cwd",
            cwd,
          ],
          { cwd: home, signal, timeout: 12000, maxBuffer: 64 * 1024, windowsHide: true },
          (error, stdout) => (error ? reject(new Error("Session naming failed.")) : resolve(stdout)),
        );
        child.stdin?.on("error", () => reject(new Error("Session naming input failed.")));
        child.stdin?.end(topic.slice(0, 1500));
      }),
    catch: providerFailure,
  });
  const result = yield* Effect.try({ try: () => JSON.parse(output), catch: providerFailure });
  return getString(result, "title")?.trim() || null;
});
