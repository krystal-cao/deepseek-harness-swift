import {
  CLASSIFICATIONS,
  NETWORK_EXPOSURES,
  accessState,
  decideRequest,
} from "./access-state.js";

const ROUTE_PATH = "/__dsh_swift/lan-url";
const JSON_CONTENT_TYPE = "application/json; charset=utf-8";

function writeJSON(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-type": JSON_CONTENT_TYPE,
    "x-content-type-options": "nosniff",
    "content-length": String(Buffer.byteLength(body, "utf8")),
  });
  response.end(body);
}

export function createLanURLRoute(state = accessState) {
  return {
    kind: "exact",
    path: ROUTE_PATH,
    handler: async (request, response) => {
      if (request.method !== "POST") {
        response.writeHead(405, { allow: "POST", "cache-control": "no-store" });
        response.end("method not allowed");
        return;
      }
      if (decideRequest(request, state) !== CLASSIFICATIONS.renderer ||
          !state.ordinaryBrowserEnabled ||
          state.networkExposure !== NETWORK_EXPOSURES.lan) {
        response.writeHead(403, { "cache-control": "no-store" });
        response.end("forbidden");
        return;
      }
      const url = state.lanAuthenticatedUrl?.();
      if (!url) {
        response.writeHead(503, { "cache-control": "no-store" });
        response.end("LAN access is not ready");
        return;
      }
      writeJSON(response, 200, { url });
    },
  };
}

export { ROUTE_PATH };
