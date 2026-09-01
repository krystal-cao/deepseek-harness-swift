import {
  BROWSER_COOKIE_NAME,
  CLASSIFICATIONS,
  accessState,
  decideRequest,
  hasValidBrowserCredential,
} from "./access-state.js";

const ROUTE_PATH = "/__dsh_swift/browser-url";
const HANDOFF_PATH = "/__dsh_swift/browser-handoff";
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

function loopbackBaseURL(state) {
  return new URL(`http://127.0.0.1:${String(state.port)}/`);
}

function cleanRootURL(baseURL, state) {
  const url = new URL(String(baseURL));
  const expectedOrigin = loopbackBaseURL(state).origin;
  if (url.protocol !== "http:" || url.origin !== expectedOrigin) {
    throw new Error("authenticated URL is outside the managed loopback server");
  }
  url.pathname = "/";
  url.search = "";
  url.hash = "";
  return url;
}

export function normalizeAuthenticatedURL(value, state, baseURL = loopbackBaseURL(state)) {
  const url = new URL(String(value));
  const cleanBase = cleanRootURL(baseURL, state);
  if (url.protocol !== cleanBase.protocol || url.origin !== cleanBase.origin || url.pathname !== "/" || url.hash !== "") {
    throw new Error("authenticated URL is outside the managed loopback server");
  }
  return url;
}

export function captureConnection(ctx) {
  let injectedConnection;
  if (ctx && typeof ctx.inject === "function") {
    ctx.inject(["connection"], (injectedContext) => {
      injectedConnection = injectedContext.connection;
    });
  }
  return () => injectedConnection;
}

function classifyProviderURL(candidate, state, baseURL) {
  const tokenValues = candidate.searchParams.getAll("token");
  const parameterNames = [...candidate.searchParams.keys()];
  if (tokenValues.length === 1 && parameterNames.length === 1 && tokenValues[0].length > 0) {
    return { mode: "browserTokenCookie", url: candidate };
  }

  const browserValues = candidate.searchParams.getAll("dsh-auth");
  if (browserValues.length === 1 && parameterNames.length === 1 && hasValidBrowserCredential({ url: candidate.toString(), headers: {} }, state)) {
    // This is the explicit compatibility shape used by the legacy adapter.
    // The old B is not reused; the new handoff gets its own B below.
    state.browserTokens.delete(browserValues[0]);
    return { mode: "legacy", url: cleanRootURL(baseURL, state) };
  }

  if (parameterNames.length === 0) {
    return { mode: "legacy", url: cleanRootURL(baseURL, state) };
  }
  throw new Error("authenticated URL has an unsupported credential contract");
}

/**
 * Ask the installed Connection service for its browser entry point. A missing
 * provider is the explicit rc.2 compatibility branch; a present provider is
 * never silently replaced after it fails or returns an invalid URL.
 */
export async function issueAuthenticatedURL(getConnection, state, baseURL = loopbackBaseURL(state)) {
  const connection = getConnection?.();
  const provider = connection && connection.authenticatedUrl;
  if (typeof provider !== "function") {
    return { mode: "legacy", url: cleanRootURL(baseURL, state) };
  }
  const candidate = normalizeAuthenticatedURL(
    await provider.call(connection, cleanRootURL(baseURL, state).origin),
    state,
    baseURL,
  );
  return classifyProviderURL(candidate, state, baseURL);
}

function issueHandoff(state, targetURL) {
  const handoffURL = state.issueBrowserHandoff?.(targetURL.toString());
  if (!handoffURL) throw new Error("browser handoff is unavailable");
  return handoffURL;
}

/** Renderer-only route that returns a local, one-time browser handoff URL. */
export function createBrowserURLRoute(ctxOrProvider, state = accessState) {
  const getConnection = typeof ctxOrProvider === "function" ? ctxOrProvider : captureConnection(ctxOrProvider);
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

      try {
        const issued = await issueAuthenticatedURL(getConnection, state);
        const url = issueHandoff(state, issued.url);
        writeJSON(response, 200, { url });
      } catch {
        // Provider failures are contract failures, not a reason to expose an
        // anonymous or old-style URL that a token-based Runtime cannot authenticate.
        writeJSON(response, 503, { error: "browser authentication unavailable" });
      }
    },
  };
}

/** Browser-only route that installs B before following the hidden upstream URL. */
export function createBrowserHandoffRoute(state = accessState) {
  return {
    kind: "exact",
    path: HANDOFF_PATH,
    handler: (request, response) => {
      if (request.method !== "GET") {
        response.writeHead(405, { allow: "GET", "cache-control": "no-store" });
        response.end("method not allowed");
        return;
      }
      const handoff = state.consumeBrowserHandoff?.(request);
      if (!handoff) {
        response.writeHead(403, { "cache-control": "no-store" });
        response.end("forbidden");
        return;
      }
      response.writeHead(303, {
        "cache-control": "no-store",
        "location": handoff.targetURL,
        "referrer-policy": "no-referrer",
        "set-cookie": `${BROWSER_COOKIE_NAME}=${handoff.browserToken}; Path=/; Max-Age=600; HttpOnly; SameSite=Strict`,
      });
      response.end();
    },
  };
}

export { HANDOFF_PATH, ROUTE_PATH };
