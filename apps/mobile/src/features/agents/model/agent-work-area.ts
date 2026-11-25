import { INPUT_LIMITS } from "@openbot/contracts/input-limits";

// Keep this catalog here until the work-area strings can move to the shared mobile catalog.
export const workAreaMessages = {
  "mobile.agent.workArea.title": "Work area",
  "mobile.agent.workArea.choose": "Choose a work area",
  "mobile.agent.workArea.change": "Change work area",
  "mobile.agent.workArea.empty": "This server has no work areas.",
  "mobile.agent.workArea.ownerRequired": "Only the server owner can choose a work area.",
  "mobile.agent.workArea.loadFailed": "Could not load work areas.",
  "mobile.agent.workArea.unsupported": "This server no longer supports work area selection.",
} as const;

export function decodeAgentWorkAreas(value: unknown): string[] {
  const areas = typeof value === "object" && value !== null && "areas" in value ? value.areas : null;
  if (
    !Array.isArray(areas) ||
    !areas.every(
      (area): area is string =>
        typeof area === "string" && Boolean(area.trim()) && area.length <= INPUT_LIMITS.identifier,
    )
  ) {
    throw new Error("The server returned invalid work areas.");
  }
  return [...new Set(areas)];
}
