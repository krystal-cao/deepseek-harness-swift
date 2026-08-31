import { createHash } from "node:crypto";
import http from "node:http";

import { BROWSER_COOKIE_NAME } from "./access-state.js";
import { issueAuthenticatedURL } from "./browser-url-route.js";

const BACKEND_HOST = "127.0.0.1";
const UPSTREAM_COOKIE_PREFIX = "dsh-auth-";
const EXCHANGE_TIMEOUT_MS = 5_000;

function cookieHeaderValue(value) {
  if (typeof value !== "string") return undefined;
  const separator = value.indexOf(";");
  const pair = (separator === -1 ? value : value.slice(0, separator)).trim();
  const equals = pair.indexOf("=");
  if (equals <= 0 || pair.includes("\r") || pair.includes("\n")) return undefined;
  return pair;
}

function expectedUpstreamCookieName(authority) {
  return UPSTREAM_COOKIE_PREFIX + createHash("sha256").update(authority).digest("base64url");
}

function extractUpstreamCookie(headers, targetURL) {
  const raw = headers?.["set-cookie"] ?? headers?.["Set-Cookie"];
  const values = Array.isArray(raw) ? raw : raw === undefined ? [] : [raw];
  const expectedName = expectedUpstreamCookieName(targetURL.host);
  const matches = [];
  for (const value of values) {
    const pair = cookieHeaderValue(String(value));
    if (pair?.startsWith(`${expectedName}=`)) matches.push(pair);
  }
  if (matches.length !== 1) throw new Error("upstream authentication cookie was not issued");
  return matches[0];
}

function cleanRedirectLocation(headers, targetURL) {
  const location = headers?.location ?? headers?.Location;
  if (typeof location !== "string") throw new Error("upstream authentication redirect was missing");
  const next = new URL(location, targetURL);
  if (next.origin !== targetURL.origin || next.pathname !== "/" || next.search !== "" || next.hash !== "") {
    throw new Error("upstream authentication redirect escaped the backend root");
  }
}

function exchangeOverLoopback(targetURL, browserToken, backendPort) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      host: BACKEND_HOST,
      port: backendPort,
      method: "GET",
      path: `${targetURL.pathname}${targetURL.search}`,
      headers: {
        host: targetURL.host,
        cookie: `${BROWSER_COOKIE_NAME}=${browserToken}`,
        "cache-control": "no-store",
      },
    }, (response) => {
      response.resume();
      response.once("end", () => {
        try {
          if (response.statusCode !== 303) throw new Error("upstream authentication exchange returned an unexpected status");
          cleanRedirectLocation(response.headers, targetURL);
          resolve(extractUpstreamCookie(response.headers, targetURL));
        } catch (error) {
          reject(error);
        }
      });
    });
    request.setTimeout(EXCHANGE_TIMEOUT_MS, () => request.destroy(new Error("upstream authentication exchange timed out")));
    request.once("error", reject);
    request.end();
  });
}

function entryIsUsable(entry, state, browserToken) {
  return entry !== undefined && entry.generation === state.generation && entry.expiresAt > Date.now() && state.browserTokens.get(browserToken) > Date.now();
}

function removeLanMapping(state, entry, browserToken) {
  if (entry.lanCredential !== undefined && state.lanBrowserTokens.get(entry.lanCredential)?.browserToken === browserToken) {
    state.lanBrowserTokens.delete(entry.lanCredential);
    state.lanTokens.delete(entry.lanCredential);
  }
}

/**
 * Keep the LAN-facing L credential separate from the backend B+U session.
 * Upstream launch URLs and cookies live only in this process memory and are
 * never copied into a LAN response.
 */
export function createUpstreamSessionBroker({ state, backendPort, getConnection }) {
  const sessions = new Map();
  const sockets = new Set();

  const broker = {
    async cookiesFor(browserToken, lanCredential) {
      const expiresAt = state.browserTokens.get(browserToken);
      if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) throw new Error("browser credential expired");

      const existing = sessions.get(browserToken);
      if (existing?.inFlight) return existing.inFlight;
      if (entryIsUsable(existing, state, browserToken)) {
        return { browserCookie: `${BROWSER_COOKIE_NAME}=${browserToken}`, upstreamCookie: existing.upstreamCookie };
      }

      const entry = {
        generation: state.generation,
        expiresAt,
        lanCredential,
        inFlight: undefined,
        upstreamCookie: undefined,
        expiryTimer: undefined,
        sockets: new Set(),
      };
      entry.expiryTimer = setTimeout(() => {
        if (sessions.get(browserToken) !== entry) return;
        sessions.delete(browserToken);
        state.browserTokens.delete(browserToken);
        removeLanMapping(state, entry, browserToken);
        for (const socket of entry.sockets) socket.destroy?.();
        entry.sockets.clear();
      }, Math.max(1, expiresAt - Date.now() + 1));
      entry.expiryTimer.unref?.();
      const exchange = (async () => {
        const issued = await issueAuthenticatedURL(
          getConnection,
          state,
          `http://${BACKEND_HOST}:${String(backendPort)}/`,
        );
        let upstreamCookie;
        if (issued.mode === "browserTokenCookie") {
          upstreamCookie = await exchangeOverLoopback(new URL(issued.url), browserToken, backendPort);
        } else if (issued.mode !== "legacy") {
          throw new Error("unsupported upstream authentication mode");
        }
        if (!entryIsUsable(entry, state, browserToken)) throw new Error("browser credential was revoked during exchange");
        entry.upstreamCookie = upstreamCookie;
        entry.inFlight = undefined;
        sessions.set(browserToken, entry);
        return { browserCookie: `${BROWSER_COOKIE_NAME}=${browserToken}`, upstreamCookie };
      })();
      entry.inFlight = exchange;
      sessions.set(browserToken, entry);
      try {
        return await exchange;
      } catch (error) {
        if (sessions.get(browserToken) === entry) {
          sessions.delete(browserToken);
          clearTimeout(entry.expiryTimer);
        }
        throw error;
      }
    },

    trackSocket(socket, browserToken) {
      if (!socket) return;
      sockets.add(socket);
      if (browserToken !== undefined) {
        const entry = sessions.get(browserToken);
        entry?.sockets.add(socket);
        socket.once?.("close", () => entry?.sockets.delete(socket));
      }
      const remove = () => sockets.delete(socket);
      socket.once?.("close", remove);
      socket.once?.("error", remove);
    },

    clear() {
      for (const entry of sessions.values()) clearTimeout(entry.expiryTimer);
      sessions.clear();
      for (const socket of sockets) socket.destroy?.();
      sockets.clear();
    },

    size() {
      return sessions.size;
    },
  };

  return broker;
}

export { expectedUpstreamCookieName };
