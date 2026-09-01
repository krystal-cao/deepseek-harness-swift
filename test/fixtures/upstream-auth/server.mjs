import http from "node:http";
import { createHash } from "node:crypto";

const AUTH_COOKIE_PREFIX = "dsh-auth-";
const LAUNCH_TOKEN = "fixture-launch-token";
const UPSTREAM_COOKIE = "fixture-upstream-cookie";

function hasCookie(request, name, expectedValue) {
  const header = request.headers.cookie;
  if (typeof header !== "string") return false;
  return header.split(";").some((part) => {
    const separator = part.indexOf("=");
    return separator !== -1 && part.slice(0, separator).trim() === name && part.slice(separator + 1).trim() === expectedValue;
  });
}

function writeBody(response, status, body, headers = {}) {
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-type": "text/plain; charset=utf-8",
    "content-length": String(Buffer.byteLength(body)),
    ...headers,
  });
  response.end(body);
}

function requestHost(request) {
  return typeof request.headers.host === "string" ? request.headers.host : "";
}

/**
 * A black-box HTTP contract fixture for the observed rc.2/alpha behavior.
 * It intentionally models responses and redirects, rather than importing or
 * copying BrowserAuth implementation code from the runtime package.
 */
export async function createUpstreamAuthFixture({ mode = "alpha", host = "127.0.0.1" } = {}) {
  const isAlpha = mode === "alpha";
  let server;
  let port = 0;
  let cookieName;
  const observed = [];

  const authorize = (request) => isAlpha && hasCookie(request, cookieName, UPSTREAM_COOKIE);
  const serverHost = () => `${host}:${String(port)}`;

  server = http.createServer((request, response) => {
    observed.push({
      kind: "http",
      method: request.method,
      url: request.url,
      host: request.headers.host,
      cookie: request.headers.cookie ?? "",
    });
    if (requestHost(request) !== serverHost()) {
      writeBody(response, 421, "mismatched authority");
      return;
    }

    const url = new URL(request.url ?? "/", `http://${requestHost(request)}`);
    const tokens = url.searchParams.getAll("token");

    if (url.pathname === "/__fixture/handoff" && !isAlpha) {
      response.writeHead(303, { location: "/" });
      response.end();
      return;
    }
    if (url.pathname === "/__fixture/handoff" && isAlpha) {
      response.writeHead(303, {
        location: `/?token=${encodeURIComponent(LAUNCH_TOKEN)}`,
        "cache-control": "no-store",
      });
      response.end();
      return;
    }

    if (url.pathname === "/" && isAlpha && tokens.length > 0) {
      if (tokens.length !== 1 || tokens[0] !== LAUNCH_TOKEN) {
        writeBody(response, 401, "dsh web authentication required; reopen the URL printed by dsh web.");
        return;
      }
      response.writeHead(303, {
        location: "/",
        "referrer-policy": "no-referrer",
        "cache-control": "no-store",
        "set-cookie": `${cookieName}=${UPSTREAM_COOKIE}; Path=/; HttpOnly; Max-Age=2592000; SameSite=Strict`,
      });
      response.end();
      return;
    }

    if (url.pathname === "/") {
      if (isAlpha && !authorize(request)) {
        writeBody(response, 401, "dsh web authentication required; reopen the URL printed by dsh web.");
        return;
      }
      writeBody(response, 200, "<!doctype html><html><body>DSH fixture</body></html>", {
        "content-type": "text/html; charset=utf-8",
      });
      return;
    }

    if (url.pathname === "/api/health") {
      if (isAlpha && !authorize(request)) {
        writeBody(response, 401, "upstream authentication required");
        return;
      }
      writeBody(response, 200, JSON.stringify({ ok: true }), {
        "content-type": "application/json; charset=utf-8",
      });
      return;
    }

    writeBody(response, 404, "not found");
  });

  server.on("upgrade", (request, socket) => {
    observed.push({
      kind: "upgrade",
      method: request.method,
      url: request.url,
      host: request.headers.host,
      cookie: request.headers.cookie ?? "",
    });
    const url = new URL(request.url ?? "/", `http://${requestHost(request)}`);
    if (requestHost(request) !== serverHost() || url.pathname !== "/api/remote.mux" || (isAlpha && !authorize(request))) {
      socket.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
      return;
    }
    socket.write("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
    setTimeout(() => socket.destroy(), 50);
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, host, () => {
      port = server.address().port;
      const authorityDigest = createHash("sha256")
        .update(host + ":" + String(port))
        .digest("base64url");
      cookieName = AUTH_COOKIE_PREFIX + authorityDigest;
      resolve();
    });
  });

  return {
    mode,
    port,
    cookieName,
    launchURL: `http://${host}:${String(port)}/?token=${encodeURIComponent(LAUNCH_TOKEN)}`,
    originURL: `http://${host}:${String(port)}/`,
    observed,
    async close() {
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

export { AUTH_COOKIE_PREFIX, LAUNCH_TOKEN, UPSTREAM_COOKIE };
