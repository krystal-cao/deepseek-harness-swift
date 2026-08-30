import {
  BROWSER_COOKIE_NAME,
  CLASSIFICATIONS,
  accessState,
  decideRequest,
  hasValidBrowserCredential,
} from "./access-state.js";

const ROUTE_PATH = "/__dsh_swift/browser-url";
const JSON_CONTENT_TYPE = "application/json; charset=utf-8";

function strictRendererRequest(request, state) {
  return decideRequest(request, state) === CLASSIFICATIONS.renderer;
}

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

function normalizeAuthenticatedURL(value, state) {
  const url = new URL(String(value));
  if (url.protocol !== "http:" || url.hostname !== "127.0.0.1" || url.port !== String(state.port)) {
    throw new Error("authenticated URL is outside the managed loopback server");
  }
  return url;
}

function loopbackBaseURL(state) {
  return new URL(`http://127.0.0.1:${String(state.port)}/`);
}

function captureConnection(ctx) {
  let injectedConnection;
  if (ctx && typeof ctx.inject === "function") {
    ctx.inject(["connection"], (injectedContext) => {
      injectedConnection = injectedContext.connection;
    });
    return () => injectedConnection;
  }
  return () => undefined;
}

async function issueAuthenticatedURL(getConnection, state) {
  const connection = getConnection();
  const provider = connection && connection.authenticatedUrl;
  if (typeof provider === "function") {
    try {
      // HostConnectionService's API takes the base URL as an argument. Keep
      // the call compatible with that API, while accepting only a URL whose
      // credential is understood by this access-state gate.
      const candidate = normalizeAuthenticatedURL(
        await provider.call(connection, loopbackBaseURL(state).origin),
        state,
      );
      if (
        candidate.searchParams.get("dsh-auth") !== null &&
        hasValidBrowserCredential({ url: candidate.toString(), headers: {} }, state)
      ) return candidate;
    } catch {
      // Older releases may expose an incompatible helper. The local adapter
      // below is the compatibility authority for this managed runtime.
    }
  }
  return normalizeAuthenticatedURL(state.authenticatedUrl(), state);
}

/**
 * Private Renderer-only bridge used by the native settings window. The
 * connection service owns URL issuance when the installed DSH release has
 * authenticatedUrl(); the access-state adapter is the compatibility provider
 * for releases that have not shipped that method yet.
 */
export function createBrowserURLRoute(ctx, state = accessState) {
  const getConnection = captureConnection(ctx);
  return {
    kind: "exact",
    path: ROUTE_PATH,
    handler: async (request, response) => {
      if (!strictRendererRequest(request, state)) {
        response.writeHead(403, { "cache-control": "no-store" });
        response.end("forbidden");
        return;
      }
      if (request.method !== "POST") {
        response.writeHead(405, { allow: "POST", "cache-control": "no-store" });
        response.end("method not allowed");
        return;
      }
      if (!state.ordinaryBrowserEnabled) {
        response.writeHead(403, { "cache-control": "no-store" });
        response.end("forbidden");
        return;
      }

      const authenticatedURL = await issueAuthenticatedURL(getConnection, state);
      // The query credential is exchanged for a browser session cookie on the
      // first page request. It never enters Node logs or Swift persistent state.
      response.setHeader(
        "set-cookie",
        `${BROWSER_COOKIE_NAME}=${authenticatedURL.searchParams.get("dsh-auth")}; Path=/; Max-Age=600; HttpOnly; SameSite=Strict`,
      );
      writeJSON(response, 200, { url: authenticatedURL.toString() });
    },
  };
}

export { ROUTE_PATH };
