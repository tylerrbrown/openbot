import { isDynamicRecord } from "../runtime-values";
import { TEAM_API_ROUTES } from "../team-api-routes";
import { decodeAgentCreateWorkArea } from "./agent-work-area-v1";
import { isAgentCreateRoute } from "./current";
import {
  decodeTeamProtocolV9WebRtcHttpRequest,
  decodeTeamProtocolV9WebRtcHttpResponse,
  encodeTeamProtocolV9WebRtcHttpRequest,
} from "./v9-webrtc-adapter";
import { decodeTeamProtocolSupportV10, hasTeamProtocolV10Lists } from "./v10";
import { decodeTeamProtocolV2Json, type TeamProtocolV2Json } from "./webrtc-framing";

function withWorkArea(method: string, path: string, source: unknown, request: TeamProtocolV2Json) {
  return isAgentCreateRoute(method, path) && isDynamicRecord(request)
    ? decodeTeamProtocolV2Json({ ...request, ...decodeAgentCreateWorkArea(source) })
    : request;
}

export function encodeTeamProtocolV10WebRtcHttpRequest(
  ...[method, path, value, options]: Parameters<typeof encodeTeamProtocolV9WebRtcHttpRequest>
) {
  return withWorkArea(method, path, value, encodeTeamProtocolV9WebRtcHttpRequest(method, path, value, options));
}

export function decodeTeamProtocolV10WebRtcHttpRequest(
  ...[method, path, value, options]: Parameters<typeof decodeTeamProtocolV9WebRtcHttpRequest>
) {
  return withWorkArea(method, path, value, decodeTeamProtocolV9WebRtcHttpRequest(method, path, value, options));
}

export function decodeTeamProtocolV10WebRtcHttpResponse(method: string, path: string, status: number, value: unknown) {
  if (method === "GET" && path === TEAM_API_ROUTES.compatibility && status === 200 && hasTeamProtocolV10Lists(value))
    return decodeTeamProtocolV2Json({ ...decodeTeamProtocolSupportV10(value) });
  return decodeTeamProtocolV9WebRtcHttpResponse(method, path, status, value);
}
