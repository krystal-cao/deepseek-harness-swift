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
import { createUpstreamSessionBroker } from "./upstream-session-broker.js";

const BROWSER_AUTH_PARAMETER = "dsh-auth";
const UPSTREAM_TOKEN_PARAMETER = "token";
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
    const port = Number(parsed.port);
    if (!Number.isSafeInteger(port) || port < 1 || port > 65535) return undefined;
    return { hostname: parsed.hostname, port, text: parsed.host };
  } catch {
    return undefined;
  }
}

function isSensitiveQueryKey(key) {
  const normalized = key.toLowerCase();
  return normalized === BROWSER_AUTH_PARAMETER || normalized === UPSTREAM_TOKEN_PARAMETER || normalized.startsWith("dsh-auth-");
}

export function requestPath(request) {
  let url;
  try {
    url = new URL(request.url ?? "/", `http://${request.headers.host}`);
  } catch {
    return undefined;
  }
  for (const key of [...url.searchParams.keys()]) {
    if (isSensitiveQueryKey(key) || key.startsWith("dsh-desktop-") || key.startsWith("dsh-swift-")) url.searchParams.delete(key);
  }
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

function deleteHeader(headers, name) {
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === name.toLowerCase()) delete headers[key];
  }
}

function cookieName(value) {
  const separator = value.indexOf("=");
  return separator === -1 ? "" : value.slice(0, separator).trim().toLowerCase();
}

function sensitiveCookieName(name) {
  return name === RENDERER_COOKIE_NAME || name === BROWSER_COOKIE_NAME || name === LAN_COOKIE_NAME || name.startsWith("dsh-auth-");
}

export function sanitizedCookies(request, browserToken, upstreamCookie) {
  const values = [];
  if (typeof request.headers?.cookie === "string") {
    for (const part of request.headers.cookie.split(";")) {
      const trimmed = part.trim();
      if (!trimmed || sensitiveCookieName(cookieName(trimmed))) continue;
      values.push(trimmed);
    }
  }
  values.push(`${BROWSER_COOKIE_NAME}=${browserToken}`);
  if (typeof upstreamCookie === "string") values.push(upstreamCookie);
  return values.join("; ");
}

export function backendHeaders(request, browserToken, upstreamCookie, backendPort) {
  const headers = { ...request.headers };
  for (const name of [
    "host",
    "origin",
    "sec-fetch-site",
    "x-forwarded-for",
    "x-forwarded-host",
    "authorization",
    ...HOP_BY_HOP_HEADERS,
  ]) deleteHeader(headers, name);
  headers.host = `${BACKEND_HOST}:${String(backendPort)}`;
  headers.cookie = sanitizedCookies(request, browserToken, upstreamCookie);
  return headers;
}

function hasSensitiveQuery(url) {
  for (const key of url.searchParams.keys()) if (isSensitiveQueryKey(key)) return true;
  return false;
}

function filteredSetCookies(value) {
  const cookies = Array.isArray(value) ? value : value === undefined ? [] : [value];
  return cookies.filter((cookie) => !sensitiveCookieName(cookieName(String(cookie))));
}

function safeLocation(value, request) {
  if (typeof value !== "string") return undefined;
  const authority = publicAuthority(request);
  const backendOrigin = `http://${BACKEND_HOST}:${String(request.backendPort)}`;
  let location;
  try {
    location = new URL(value, backendOrigin);
  } catch {
    return undefined;
  }
  if (hasSensitiveQuery(location)) return undefined;
  if (location.origin === backendOrigin && authority) {
    return `http://${authority.text}${location.pathname || "/"}${location.search}${location.hash}`;
  }
  return value;
}

export function responseHeaders(headers, request) {
  const output = {};
  for (const [name, value] of Object.entries(headers)) {
    const normalized = name.toLowerCase();
    if (HOP_BY_HOP_HEADERS.has(normalized)) continue;
    if (normalized === "set-cookie") {
      const cookies = filteredSetCookies(value);
      if (cookies.length > 0) output["set-cookie"] = cookies;
      continue;
    }
    if (normalized === "location") {
      const location = safeLocation(typeof value === "string" ? value : value?.[0], request);
      if (location !== undefined) output.location = location;
      continue;
    }
    output[name] = value;
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

export function appendSessionCookie(headers, lanCredential, request) {
  const cookies = filteredSetCookies(headers["set-cookie"] ?? headers["Set-Cookie"]);
  cookies.push(`${LAN_COOKIE_NAME}=${lanCredential}; Path=/; Max-Age=600; HttpOnly; SameSite=Strict`);
  headers["set-cookie"] = cookies;
  let url;
  try {
    url = new URL(request.url ?? "/", "http://127.0.0.1");
  } catch {
    return;
  }
  if (hasSensitiveQuery(url)) headers["referrer-policy"] = "no-referrer";
}

async function exchangeCredential(broker, credential) {
  return broker.cookiesFor(credential.browserToken, credential.lanCredential);
}

export function createLanHTTPIngress({ backendPort, state, getConnection = () => undefined, listenHost = "0.0.0.0", listenPort = 0, addressProvider = getLanIPv4Addresses }) {
  let server;
  let actualPort = 0;
  const sockets = new Set();
  const broker = createUpstreamSessionBroker({ state, backendPort, getConnection });
  state.attachSessionBroker?.(broker);

  const ingress = {
    async start() {
      if (server) return;
      server = http.createServer((request, response) => {
        void (async () => {
          if (!requestAllowed(request, state, actualPort, addressProvider)) {
            forbidden(response);
            return;
          }
          const credential = browserCredentialForLan(request, state);
          if (!credential) {
            forbidden(response);
            return;
          }
          const path = requestPath(request);
          if (!path) {
            forbidden(response);
            return;
          }

          let session;
          try {
            session = await exchangeCredential(broker, credential);
          } catch {
            badGateway(response);
            return;
          }
          const headers = backendHeaders(request, credential.browserToken, session.upstreamCookie, backendPort);
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
          request.once("aborted", () => proxyRequest.destroy());
          request.pipe(proxyRequest);
        })().catch(() => badGateway(response));
      });
      server.on("connection", (socket) => {
        sockets.add(socket);
        broker.trackSocket(socket);
        socket.once("close", () => sockets.delete(socket));
      });
      server.on("upgrade", (request, socket, head) => {
        void (async () => {
          const path = requestPath(request);
          if (!requestAllowed(request, state, actualPort, addressProvider) || !path) {
            forbiddenSocket(socket);
            return;
          }
          const credential = browserCredentialForLan(request, state);
          if (!credential) {
            forbiddenSocket(socket);
            return;
          }
          let session;
          try {
            session = await exchangeCredential(broker, credential);
          } catch {
            forbiddenSocket(socket);
            return;
          }

          const backendSocket = net.connect(backendPort, BACKEND_HOST);
          sockets.add(backendSocket);
          broker.trackSocket(socket, credential.browserToken);
          broker.trackSocket(backendSocket, credential.browserToken);
          backendSocket.once("close", () => sockets.delete(backendSocket));
          backendSocket.once("connect", () => {
            const headers = backendHeaders(request, credential.browserToken, session.upstreamCookie, backendPort);
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
        })().catch(() => forbiddenSocket(socket));
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
      broker.clear();
      state.detachSessionBroker?.(broker);
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
      return addressProvider();
    },

    isRunning() {
      return server !== undefined && actualPort > 0;
    },

    broker() {
      return broker;
    },
  };

  return ingress;
}
