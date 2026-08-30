import http from "node:http";
import net from "node:net";
import os from "node:os";

import {
  BROWSER_COOKIE_NAME,
  LAN_COOKIE_NAME,
  NETWORK_EXPOSURES,
  RENDERER_COOKIE_NAME,
  browserCredentialForLan,
  hasValidLanCredential,
} from "./access-state.js";

const BROWSER_AUTH_PARAMETER = "dsh-auth";
const BACKEND_HOST = "127.0.0.1";
const FORBIDDEN_BODY = "forbidden";
const BAD_GATEWAY_BODY = "bad gateway";
const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

function isPrivateIPv4(address) {
  const octets = address.split(".").map(Number);
  if (octets.length !== 4 || octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) return false;
  if (octets[0] === 127) return false;
  if (octets[0] === 10) return true;
  if (octets[0] === 192 && octets[1] === 168) return true;
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  if (octets[0] === 169 && octets[1] === 254) return true;
  return false;
}

export function getLanIPv4Addresses(networkInterfaces = os.networkInterfaces()) {
  const addresses = [];
  for (const entries of Object.values(networkInterfaces ?? {})) {
    for (const entry of entries ?? []) {
      if (entry?.family === "IPv4" && !entry.internal && isPrivateIPv4(entry.address) && !addresses.includes(entry.address)) {
        addresses.push(entry.address);
      }
    }
  }
  return addresses.sort((left, right) => left.localeCompare(right, "en", { numeric: true }));
}

function publicAuthority(request) {
  const hostHeader = request.headers?.host;
  if (typeof hostHeader !== "string" || hostHeader.length > 128) return undefined;
  try {
    const parsed = new URL(`http://${hostHeader}`);
    if (!parsed.hostname || parsed.port === "") return undefined;
    return { hostname: parsed.hostname, port: Number(parsed.port), text: hostHeader };
  } catch {
    return undefined;
  }
}

function requestPath(request) {
  let url;
  try {
    url = new URL(request.url ?? "/", `http://${request.headers.host}`);
  } catch {
    return undefined;
  }
  url.searchParams.delete(BROWSER_AUTH_PARAMETER);
  return `${url.pathname || "/"}${url.search ? url.search : ""}`;
}

function requestOrigin(request, authority) {
  const origin = request.headers?.origin;
  if (origin === undefined || origin === "") return true;
  return origin === `http://${authority.hostname}:${String(authority.port)}`;
}

function requestAllowed(request, state, listenPort, addressProvider) {
  if (state.networkExposure !== NETWORK_EXPOSURES.lan || !state.ordinaryBrowserEnabled) return false;
  if (!hasValidLanCredential(request, state)) return false;
  const authority = publicAuthority(request);
  if (!authority || authority.port !== listenPort || !addressProvider().includes(authority.hostname)) return false;
  if (!requestOrigin(request, authority)) return false;
  if (request.headers?.["sec-fetch-site"] === "cross-site") return false;
  return true;
}

function sanitizedCookies(request, browserToken) {
  const values = [];
  if (typeof request.headers?.cookie === "string") {
    for (const part of request.headers.cookie.split(";")) {
      const separator = part.indexOf("=");
      if (separator === -1) continue;
      const name = part.slice(0, separator).trim();
      if (name === RENDERER_COOKIE_NAME || name === BROWSER_COOKIE_NAME || name === LAN_COOKIE_NAME) continue;
      values.push(part.trim());
    }
  }
  values.push(`${BROWSER_COOKIE_NAME}=${browserToken}`);
  return values.join("; ");
}

function backendHeaders(request, browserToken, backendPort) {
  const headers = { ...request.headers };
  delete headers.host;
  delete headers.origin;
  delete headers["sec-fetch-site"];
  delete headers["x-forwarded-for"];
  delete headers["x-forwarded-host"];
  headers.host = `${BACKEND_HOST}:${String(backendPort)}`;
  headers.cookie = sanitizedCookies(request, browserToken);
  return headers;
}

function responseHeaders(headers, request) {
  const output = {};
  for (const [name, value] of Object.entries(headers)) {
    if (!HOP_BY_HOP_HEADERS.has(name.toLowerCase())) output[name] = value;
  }
  const location = output.location;
  if (typeof location === "string") {
    const authority = publicAuthority(request);
    const backendOrigin = `http://${BACKEND_HOST}:${String(request.backendPort)}`;
    if (authority) output.location = location.replace(backendOrigin, `http://${authority.text}`);
  }
  return output;
}

function forbidden(response) {
  response.writeHead(403, {
    "cache-control": "no-store",
    "content-type": "text/plain; charset=utf-8",
    "x-content-type-options": "nosniff",
    "content-length": String(Buffer.byteLength(FORBIDDEN_BODY)),
    connection: "close",
  });
  response.end(FORBIDDEN_BODY);
}

function forbiddenSocket(socket) {
  if (!socket.destroyed) {
    socket.end(
      `HTTP/1.1 403 Forbidden\r\nCache-Control: no-store\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${String(Buffer.byteLength(FORBIDDEN_BODY))}\r\nConnection: close\r\n\r\n${FORBIDDEN_BODY}`,
    );
  }
}

function badGateway(response) {
  if (response.headersSent) {
    response.destroy();
    return;
  }
  response.writeHead(502, {
    "cache-control": "no-store",
    "content-type": "text/plain; charset=utf-8",
    "content-length": String(Buffer.byteLength(BAD_GATEWAY_BODY)),
    connection: "close",
  });
  response.end(BAD_GATEWAY_BODY);
}

function appendSessionCookie(headers, lanCredential, request) {
  const existing = headers["set-cookie"] ?? headers["Set-Cookie"];
  const cookies = (Array.isArray(existing) ? existing : existing ? [existing] : [])
    .filter((cookie) => !String(cookie).startsWith(`${BROWSER_COOKIE_NAME}=`) && !String(cookie).startsWith(`${LAN_COOKIE_NAME}=`));
  cookies.push(`${LAN_COOKIE_NAME}=${lanCredential}; Path=/; Max-Age=600; HttpOnly; SameSite=Strict`);
  headers["set-cookie"] = cookies;
  if (new URL(request.url ?? "/", "http://127.0.0.1").searchParams.has(BROWSER_AUTH_PARAMETER)) {
    headers["referrer-policy"] = "no-referrer";
  }
}

export function createLanHTTPIngress({ backendPort, state, listenHost = "0.0.0.0", listenPort = 0, addressProvider = getLanIPv4Addresses }) {
  let server;
  let actualPort = 0;
  const sockets = new Set();

  const ingress = {
    async start() {
      if (server) return;
      server = http.createServer((request, response) => {
        const credential = browserCredentialForLan(request, state);
        if (!requestAllowed(request, state, actualPort, addressProvider) || !credential) {
          forbidden(response);
          return;
        }

        const path = requestPath(request);
        if (!path) {
          forbidden(response);
          return;
        }
        const headers = backendHeaders(request, credential.browserToken, backendPort);
        const proxyRequest = http.request({
          host: BACKEND_HOST,
          port: backendPort,
          method: request.method,
          path,
          headers,
        }, (proxyResponse) => {
          const outputHeaders = responseHeaders(proxyResponse.headers, { ...request, backendPort });
          appendSessionCookie(outputHeaders, credential.lanCredential, request);
          response.writeHead(proxyResponse.statusCode ?? 502, outputHeaders);
          proxyResponse.pipe(response);
        });
        proxyRequest.once("error", () => badGateway(response));
        request.pipe(proxyRequest);
      });
      server.on("connection", (socket) => {
        sockets.add(socket);
        socket.once("close", () => sockets.delete(socket));
      });
      server.on("upgrade", (request, socket, head) => {
        const credential = browserCredentialForLan(request, state);
        const path = requestPath(request);
        if (!requestAllowed(request, state, actualPort, addressProvider) || !credential || !path) {
          forbiddenSocket(socket);
          return;
        }

        const backendSocket = net.connect(backendPort, BACKEND_HOST);
        sockets.add(backendSocket);
        backendSocket.once("close", () => sockets.delete(backendSocket));
        backendSocket.once("connect", () => {
          const headers = backendHeaders(request, credential.browserToken, backendPort);
          headers.connection = "Upgrade";
          headers.upgrade = request.headers.upgrade ?? "websocket";
          const lines = [`${request.method ?? "GET"} ${path} HTTP/1.1`];
          for (const [name, value] of Object.entries(headers)) {
            if (Array.isArray(value)) {
              for (const item of value) lines.push(`${name}: ${item}`);
            } else if (value !== undefined) {
              lines.push(`${name}: ${value}`);
            }
          }
          backendSocket.write(`${lines.join("\r\n")}\r\n\r\n`);
          if (head?.length) backendSocket.write(head);
          socket.pipe(backendSocket).pipe(socket);
        });
        backendSocket.once("error", () => {
          if (!socket.destroyed) forbiddenSocket(socket);
        });
      });
      server.on("connect", (_request, socket) => socket.end());

      await new Promise((resolve, reject) => {
        const onError = (error) => {
          server?.off("listening", onListening);
          server = undefined;
          reject(error);
        };
        const onListening = () => {
          server?.off("error", onError);
          const address = server?.address();
          actualPort = typeof address === "object" && address ? address.port : 0;
          resolve();
        };
        server.once("error", onError);
        server.once("listening", onListening);
        server.listen(listenPort, listenHost);
      });
    },

    async stop() {
      if (!server) return;
      const current = server;
      server = undefined;
      actualPort = 0;
      for (const socket of sockets) socket.destroy();
      sockets.clear();
      await new Promise((resolve) => current.close(() => resolve()));
    },

    port() {
      return actualPort;
    },

    addresses() {
      return getLanIPv4Addresses();
    },

    isRunning() {
      return server !== undefined && actualPort > 0;
    },
  };

  return ingress;
}
