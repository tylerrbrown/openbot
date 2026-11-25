import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { type DynamicRecord, isDynamicRecord } from "@openbot/contracts/runtime-values";

// shortcut: fixed LifeOS paths of this computer; move them to host settings when another host needs Work areas.
const REPO_HOME = "C:\\Users\\tyler.TYWARE\\SynologyDrive\\Claude";
const WORK = `${REPO_HOME}\\shared\\bin\\work.cmd`;
const LIFEOS = "C:\\LifeOS\\lifeos.cmd";
const TIMEOUT_MS = 60_000;
// .cmd files need cmd.exe, so every argument must be shell-safe: these patterns allow no cmd metacharacters.
const SAFE_AREA = /^[a-z0-9][a-z0-9/_-]*$/;

export function workAreaSetupAvailable(): boolean {
  return process.platform === "win32" && existsSync(REPO_HOME);
}

function run(command: string, args: readonly string[]): Promise<DynamicRecord> {
  for (const arg of args) if (!/^[A-Za-z0-9/_.-]+$/.test(arg)) throw new Error(`Unsafe argument: ${arg}`);
  return new Promise((resolve, reject) => {
    execFile(
      "C:\\Windows\\System32\\cmd.exe",
      ["/d", "/c", command, ...args, "--json", "--no-input"],
      { cwd: REPO_HOME, timeout: TIMEOUT_MS, windowsHide: true, maxBuffer: 16 * 1024 * 1024 },
      (error, stdout) => {
        if (error) return reject(new Error(`${command.split("\\").pop()} ${args[0]} ${args[1] ?? ""} failed`));
        try {
          const value = JSON.parse(stdout);
          if (!isDynamicRecord(value)) throw new Error("Expected an object");
          resolve(value);
        } catch {
          reject(new Error(`${command.split("\\").pop()} ${args[0]} returned no JSON`));
        }
      },
    );
  });
}

export async function listWorkAreas(): Promise<string[]> {
  if (!workAreaSetupAvailable()) throw new Error("Work area setup is not available on this host.");
  const { areas } = await run(WORK, ["area", "list"]);
  if (!Array.isArray(areas)) throw new Error("The host did not return a Work area list.");
  return areas.flatMap((area: unknown) =>
    isDynamicRecord(area) && area.retired === null && typeof area.path === "string" && SAFE_AREA.test(area.path)
      ? [area.path]
      : [],
  );
}

async function step(label: string, task: () => Promise<string>): Promise<string> {
  try {
    return `- ${label}: ${await task()}`;
  } catch (error) {
    return `- ${label}: failed (${error instanceof Error ? error.message : String(error)})`;
  }
}

/** Runs host checks for a validated area. Never use the operator's memory login for a new bot. */
export async function bootstrapWorkArea(area: string): Promise<string> {
  if (!SAFE_AREA.test(area)) throw new Error("Invalid Work area.");
  const lines = await Promise.all([
    "- Global memory: not run (no agent-scoped login)",
    "- Private memory: not configured (no verified lane binding)",
    step("Charter", async () => {
      const { stamp, rules } = await run(LIFEOS, ["charter", "resolve", "--area", area, "--harness", "pi"]);
      const revision = typeof stamp === "string" ? /^Charter revision \d+\b/.exec(stamp)?.[0] : undefined;
      if (!revision || !Array.isArray(rules)) throw new Error("No verified revision was returned.");
      return `${revision} resolved for Pi (${rules.length} rules); not injected into chat`;
    }),
    step("Next Work", async () => {
      const { jobs } = await run(WORK, ["next", area]);
      if (!Array.isArray(jobs)) throw new Error("No job list was returned.");
      return jobs.length ? `${jobs.length} ready` : "no ready Jobs";
    }),
  ]);
  return ["Startup receipt", `- Work area: ${area}`, ...lines].join("\n");
}
