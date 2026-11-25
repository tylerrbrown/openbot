import { INPUT_LIMITS } from "../input-limits";
import { isDynamicRecord } from "../runtime-values";
import { adminRoute, fields, list, type OptionalRouteCodec, string } from "./admin-wire";

export const AGENT_WORK_AREA_CAPABILITY = "agent-work-area-v1";

export const AGENT_WORK_AREA_ROUTES = { list: "/v1/work-areas" } as const;

export interface WorkAreasResponse {
  areas: string[];
}

const area = string(INPUT_LIMITS.identifier);

export const AGENT_WORK_AREA_CODECS: ReadonlyMap<string, OptionalRouteCodec> = new Map([
  [AGENT_WORK_AREA_ROUTES.list, adminRoute(() => null, fields({ areas: list(area, 10_000) }))],
]);

export function decodeAgentCreateWorkArea(source: unknown): { workArea?: string } {
  if (!isDynamicRecord(source) || source.workArea === undefined) return {};
  if (
    typeof source.workArea !== "string" ||
    source.workArea.length > INPUT_LIMITS.identifier ||
    !source.workArea.trim()
  )
    throw new Error("Invalid Work area.");
  return { workArea: source.workArea };
}
