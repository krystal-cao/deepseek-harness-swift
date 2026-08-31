import { timingSafeEqual } from "node:crypto";
import { randomBytes } from "node:crypto";

export const RENDERER_COOKIE_NAME = "dsh_swift_renderer";
export const BROWSER_COOKIE_NAME = "dsh_browser_auth";
export const LAN_COOKIE_NAME = "dsh_lan_auth";
export const RENDERER_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/u;
export const BROWSER_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/u;
export const CLASSIFICATIONS = Object.freeze({
  renderer: "renderer",
  browser: "browser",
  denied: "denied",
});
export const NETWORK_EXPOSURES = Object.freeze({
  loopback: "loopback",
  lan: "lan",
});

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const RESERVED_PARAMETER_PREFIXES = ["dsh-desktop-", "dsh-swift-"];
const BROWSER_AUTH_PARAMETER = "dsh-auth";
const BROWSER_HANDOFF_PARAMETER = "dsh-browser-ticket";
const BROWSER_AUTH_TTL_MS = 10 * 60 * 1000;

function isCanonicalRendererToken(value) {
  if (typeof value !== "string" || !RENDERER_TOKEN_PATTERN.test(value)) return false;
  try {
    const bytes = Buffer.from(value, "base64url");
    return bytes.length === 32 && bytes.toString("base64url") === value;
  } catch {
    return false;
  }
}

function isCanonicalBrowserToken(value) {
  if (typeof value !== "string" || !BROWSER_TOKEN_PATTERN.test(value)) return false;
  try {
    const bytes = Buffer.from(value, "base64url");
    return bytes.length === 32 && bytes.toString("base64url") === value;
  } catch {
    return false;
  }
}

export function isValidGeneration(value) {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/**
 * Extract a single renderer cookie without accepting malformed duplicates.
 * The value is deliberately not decoded: renderer tokens are URL-safe by
 * construction and must compare byte-for-byte with the current generation.
 */
export function rendererCookieValue(cookieHeader) {
  if (typeof cookieHeader !== "string") return undefined;
  const matches = [];
  for (const part of cookieHeader.split(";")) {
    const separator = part.indexOf("=");
    if (separator === -1) continue;
    const name = part.slice(0, separator).trim();
    if (name !== RENDERER_COOKIE_NAME) continue;
    matches.push(part.slice(separator + 1).trim());
  }
  if (matches.length !== 1) return undefined;
  return matches[0];
}

export function hasValidRendererCookie(headers, expectedToken) {
  if (!isCanonicalRendererToken(expectedToken)) return false;
  const cookieHeader = headers?.cookie;
  const candidate = rendererCookieValue(cookieHeader);
  if (!isCanonicalRendererToken(candidate)) return false;
  const expected = Buffer.from(expectedToken, "utf8");
  const actual = Buffer.from(candidate, "utf8");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

function cookieValue(cookieHeader, name) {
  if (typeof cookieHeader !== "string") return undefined;
  const matches = [];
  for (const part of cookieHeader.split(";")) {
    const separator = part.indexOf("=");
    if (separator === -1) continue;
    if (part.slice(0, separator).trim() !== name) continue;
    matches.push(part.slice(separator + 1).trim());
  }
  return matches.length === 1 ? matches[0] : undefined;
}

function browserTokenFromURL(rawUrl) {
  if (typeof rawUrl !== "string") return undefined;
  let url;
  try {
    url = new URL(rawUrl, "http://127.0.0.1");
  } catch {
    return undefined;
  }
  const values = url.searchParams.getAll(BROWSER_AUTH_PARAMETER);
  return values.length === 1 && isCanonicalBrowserToken(values[0]) ? values[0] : undefined;
}

function browserHandoffTokenFromURL(rawUrl) {
  if (typeof rawUrl !== "string") return undefined;
  let url;
  try {
    url = new URL(rawUrl, "http://127.0.0.1");
  } catch {
    return undefined;
  }
  const values = url.searchParams.getAll(BROWSER_HANDOFF_PARAMETER);
  return values.length === 1 && isCanonicalBrowserToken(values[0]) ? values[0] : undefined;
}

function browserTokenFromCookie(headers) {
  const value = cookieValue(headers?.cookie, BROWSER_COOKIE_NAME);
  return isCanonicalBrowserToken(value) ? value : undefined;
}

function lanTokenFromCookie(headers) {
  const value = cookieValue(headers?.cookie, LAN_COOKIE_NAME);
  return isCanonicalBrowserToken(value) ? value : undefined;
}

function lanTokenFromURL(rawUrl) {
  if (typeof rawUrl !== "string") return undefined;
  let url;
  try {
    url = new URL(rawUrl, "http://127.0.0.1");
  } catch {
    return undefined;
  }
  const values = url.searchParams.getAll(BROWSER_AUTH_PARAMETER);
  return values.length === 1 && isCanonicalBrowserToken(values[0]) ? values[0] : undefined;
}

export function hasValidLanCredential(request, state) {
  if (state.networkExposure !== NETWORK_EXPOSURES.lan || !state.ordinaryBrowserEnabled) return false;
  const candidate = lanCredentialFromRequest(request, state);
  return candidate !== undefined;
}

export function lanCredentialFromRequest(request, state) {
  if (state.networkExposure !== NETWORK_EXPOSURES.lan || !state.ordinaryBrowserEnabled) return undefined;
  const candidate = lanTokenFromURL(request?.url) ?? lanTokenFromCookie(request?.headers);
  return candidate !== undefined && state.lanTokens.has(candidate) && state.lanTokens.get(candidate) > Date.now()
    ? candidate
    : undefined;
}

/**
 * Convert a LAN-only credential into a separate backend Browser credential.
 * The LAN client receives only LAN_COOKIE_NAME; the backend sees only the
 * short-lived browser token stored in browserTokens.
 */
export function browserCredentialForLan(request, state) {
  const lanCredential = lanCredentialFromRequest(request, state);
  if (lanCredential === undefined) return undefined;

  const now = Date.now();
  const existing = state.lanBrowserTokens.get(lanCredential);
  if (existing && existing.expiresAt > now && state.browserTokens.get(existing.browserToken) > now) {
    return { lanCredential, browserToken: existing.browserToken };
  }
  if (existing) state.browserTokens.delete(existing.browserToken);

  const browserToken = randomBytes(32).toString("base64url");
  const expiresAt = state.lanTokens.get(lanCredential);
  if (!Number.isFinite(expiresAt) || expiresAt <= now) return undefined;
  state.lanBrowserTokens.set(lanCredential, { browserToken, expiresAt });
  state.browserTokens.set(browserToken, expiresAt);
  return { lanCredential, browserToken };
}

export function hasValidBrowserCredential(request, state) {
  const candidates = [browserTokenFromURL(request?.url), browserTokenFromCookie(request?.headers)];
  return candidates.some((candidate) => candidate !== undefined && state.browserTokens.has(candidate) && state.browserTokens.get(candidate) > Date.now());
}

export function browserCredentialFromURL(request, state) {
  const candidate = browserTokenFromURL(request?.url);
  return candidate !== undefined && state.browserTokens.get(candidate) > Date.now() ? candidate : undefined;
}

export function hasReservedDesktopParameter(rawUrl) {
  if (typeof rawUrl !== "string") return false;
  let url;
  try {
    url = new URL(rawUrl, "http://127.0.0.1");
  } catch {
    return true;
  }
  for (const key of url.searchParams.keys()) {
    if (RESERVED_PARAMETER_PREFIXES.some((prefix) => key.startsWith(prefix))) return true;
  }
  return false;
}

function readHeader(headers, name) {
  if (!headers) return undefined;
  const value = headers[name] ?? headers[name.toLowerCase()];
  if (Array.isArray(value)) return value[0];
  return typeof value === "string" ? value : undefined;
}

function expectedAuthority(port) {
  return `127.0.0.1:${String(port)}`;
}

/**
 * Return the current access classification. Managed launches stay denied until
 * Swift's generation message completes the control handshake. Unmanaged CLI
 * launches intentionally retain the upstream browser behavior.
 */
export function decideRequest(request, state) {
  if (!state.managedLaunch) return CLASSIFICATIONS.browser;
  if (!state.initialized) return CLASSIFICATIONS.denied;
  if (hasValidRendererCookie(request?.headers, state.rendererToken)) return CLASSIFICATIONS.renderer;
  if (state.ordinaryBrowserEnabled && hasValidBrowserCredential(request, state)) return CLASSIFICATIONS.browser;
  return CLASSIFICATIONS.denied;
}

export function requestPassesLoopbackFence(request, state) {
  if (!state.managedLaunch) return true;
  const host = readHeader(request?.headers, "host");
  if (host !== expectedAuthority(state.port)) return false;
  const origin = readHeader(request?.headers, "origin");
  return origin === undefined || origin === "" || origin === `http://127.0.0.1:${String(state.port)}`;
}

export function createAccessState({ managedLaunch, port }) {
  const state = {
    managedLaunch: managedLaunch === true,
    port,
    initialized: managedLaunch !== true,
    generation: undefined,
    rendererToken: undefined,
    ordinaryBrowserEnabled: managedLaunch !== true,
    networkExposure: NETWORK_EXPOSURES.loopback,
    serverReady: false,
    policyRevision: 0,
    ordinarySockets: new Set(),
    policyObservers: new Set(),
    browserTokens: new Map(),
    browserHandoffs: new Map(),
    lanTokens: new Map(),
    lanBrowserTokens: new Map(),
    lanIngress: undefined,
    sessionBroker: undefined,
  };

  state.initializeGeneration = ({ generation, rendererToken, ordinaryBrowserEnabled, networkExposure = NETWORK_EXPOSURES.loopback }) => {
    if (state.initialized) throw new Error("desktop generation already initialized");
    if (!isValidGeneration(generation) || !isCanonicalRendererToken(rendererToken) || typeof ordinaryBrowserEnabled !== "boolean" || !Object.values(NETWORK_EXPOSURES).includes(networkExposure) || (networkExposure === NETWORK_EXPOSURES.lan && !ordinaryBrowserEnabled)) {
      throw new Error("invalid desktop generation");
    }
    state.generation = generation;
    state.rendererToken = rendererToken;
    state.ordinaryBrowserEnabled = ordinaryBrowserEnabled;
    state.networkExposure = networkExposure;
    state.policyRevision = 0;
    state.initialized = true;
  };

  state.applyPolicy = async ({ generation, revision, ordinaryBrowserEnabled, networkExposure = NETWORK_EXPOSURES.loopback }) => {
    if (!state.initialized || generation !== state.generation || !Number.isSafeInteger(revision) || revision < 1 || typeof ordinaryBrowserEnabled !== "boolean" || !Object.values(NETWORK_EXPOSURES).includes(networkExposure) || (networkExposure === NETWORK_EXPOSURES.lan && !ordinaryBrowserEnabled)) {
      throw new Error("invalid desktop policy");
    }
    if (revision <= state.policyRevision) {
      return { revision: state.policyRevision, ordinaryBrowserEnabled: state.ordinaryBrowserEnabled, networkExposure: state.networkExposure, changed: false };
    }
    if (revision !== state.policyRevision + 1) throw new Error("desktop policy revision gap");
    const previous = state.ordinaryBrowserEnabled;
    const previousExposure = state.networkExposure;
    state.policyRevision = revision;
    state.ordinaryBrowserEnabled = ordinaryBrowserEnabled;
    state.networkExposure = networkExposure;
    if (!ordinaryBrowserEnabled) state.revokeBrowserCredentials();
    if (!ordinaryBrowserEnabled || networkExposure !== NETWORK_EXPOSURES.lan) {
      state.clearLanCredentials();
    }
    for (const observer of state.policyObservers) await observer({
      revision,
      ordinaryBrowserEnabled,
      networkExposure,
      previousOrdinaryBrowserEnabled: previous,
      previousNetworkExposure: previousExposure,
    });
    return { revision, ordinaryBrowserEnabled, networkExposure, changed: previous !== ordinaryBrowserEnabled || previousExposure !== networkExposure };
  };

  state.markServerReady = () => {
    state.serverReady = true;
  };

  // The installed DSH release does not yet expose its documented
  // connection.authenticatedUrl() helper. Keep the short-lived browser
  // credential entirely in the Host process so the Swift side never creates
  // or persists a second token authority.
  state.authenticatedUrl = () => {
    const token = randomBytes(32).toString("base64url");
    state.browserTokens.set(token, Date.now() + BROWSER_AUTH_TTL_MS);
    for (const [oldToken, expiresAt] of state.browserTokens) {
      if (expiresAt <= Date.now()) state.browserTokens.delete(oldToken);
    }
    return `http://127.0.0.1:${String(state.port)}/?${BROWSER_AUTH_PARAMETER}=${encodeURIComponent(token)}`;
  };

  state.issueBrowserHandoff = (targetURL) => {
    if (!state.initialized || !state.ordinaryBrowserEnabled || typeof targetURL !== "string") return undefined;
    let target;
    try {
      target = new URL(targetURL);
    } catch {
      return undefined;
    }
    if (target.protocol !== "http:" || target.hostname !== "127.0.0.1" || target.port !== String(state.port) || target.pathname !== "/" || target.hash !== "") return undefined;
    const targetKeys = [...target.searchParams.keys()];
    const tokenValues = target.searchParams.getAll("token");
    if (targetKeys.length > 1 || (targetKeys.length === 1 && (tokenValues.length !== 1 || tokenValues[0].length === 0))) return undefined;
    const now = Date.now();
    for (const [ticket, handoff] of state.browserHandoffs) {
      if (handoff.expiresAt <= now || handoff.generation !== state.generation) state.browserHandoffs.delete(ticket);
    }
    const browserToken = randomBytes(32).toString("base64url");
    const ticket = randomBytes(32).toString("base64url");
    const expiresAt = now + BROWSER_AUTH_TTL_MS;
    state.browserTokens.set(browserToken, expiresAt);
    state.browserHandoffs.set(ticket, {
      browserToken,
      targetURL: target.toString(),
      expiresAt,
      generation: state.generation,
      purpose: "browser",
    });
    const url = new URL(`http://127.0.0.1:${String(state.port)}/__dsh_swift/browser-handoff`);
    url.searchParams.set(BROWSER_AUTH_PARAMETER, browserToken);
    url.searchParams.set(BROWSER_HANDOFF_PARAMETER, ticket);
    return url.toString();
  };

  state.consumeBrowserHandoff = (request) => {
    if (!state.initialized || !state.ordinaryBrowserEnabled) return undefined;
    const ticket = browserHandoffTokenFromURL(request?.url);
    const browserToken = browserTokenFromURL(request?.url);
    if (ticket === undefined || browserToken === undefined) return undefined;
    const handoff = state.browserHandoffs.get(ticket);
    const now = Date.now();
    if (!handoff || handoff.purpose !== "browser" || handoff.generation !== state.generation || handoff.browserToken !== browserToken || handoff.expiresAt <= now || state.browserTokens.get(browserToken) <= now) {
      if (handoff?.expiresAt <= now) state.browserHandoffs.delete(ticket);
      return undefined;
    }
    // The ticket is one-time. The separate B credential deliberately survives
    // this handoff so it can accompany the provider's token redirect and all
    // subsequent ordinary browser requests until policy expiry.
    state.browserHandoffs.delete(ticket);
    return { browserToken, targetURL: handoff.targetURL };
  };

  state.revokeBrowserCredentials = () => {
    state.browserTokens.clear();
    state.browserHandoffs.clear();
    state.sessionBroker?.clear?.();
  };

  state.attachSessionBroker = (broker) => {
    state.sessionBroker = broker;
  };

  state.detachSessionBroker = (broker) => {
    if (state.sessionBroker === broker) state.sessionBroker = undefined;
  };

  state.attachLanIngress = (ingress) => {
    state.lanIngress = ingress;
  };

  state.detachLanIngress = (ingress) => {
    if (state.lanIngress === ingress) state.lanIngress = undefined;
    state.clearLanCredentials();
  };

  state.lanAuthenticatedUrl = () => {
    if (state.networkExposure !== NETWORK_EXPOSURES.lan || !state.ordinaryBrowserEnabled || !state.lanIngress) return undefined;
    const address = state.lanIngress.addresses()[0];
    const port = state.lanIngress.port();
    if (!address || !port) return undefined;
    const token = randomBytes(32).toString("base64url");
    state.lanTokens.set(token, Date.now() + BROWSER_AUTH_TTL_MS);
    for (const [oldToken, expiresAt] of state.lanTokens) {
      if (expiresAt <= Date.now()) state.lanTokens.delete(oldToken);
    }
    return `http://${address}:${String(port)}/?${BROWSER_AUTH_PARAMETER}=${encodeURIComponent(token)}`;
  };

  state.observePolicy = (observer) => {
    state.policyObservers.add(observer);
    return () => state.policyObservers.delete(observer);
  };

  state.trackOrdinarySocket = (socket) => {
    state.ordinarySockets.add(socket);
    const remove = () => state.ordinarySockets.delete(socket);
    socket.once("close", remove);
    socket.once("error", remove);
    return remove;
  };

  state.closeOrdinarySockets = () => {
    for (const socket of state.ordinarySockets) socket.destroy();
    state.ordinarySockets.clear();
  };

  state.clearLanCredentials = () => {
    for (const { browserToken } of state.lanBrowserTokens.values()) {
      state.browserTokens.delete(browserToken);
    }
    state.lanTokens.clear();
    state.lanBrowserTokens.clear();
    state.sessionBroker?.clear?.();
  };

  state.shutdownControlledAccess = async () => {
    state.ordinaryBrowserEnabled = false;
    state.networkExposure = NETWORK_EXPOSURES.loopback;
    state.revokeBrowserCredentials();
    state.closeOrdinarySockets();
    const ingress = state.lanIngress;
    state.detachLanIngress(ingress);
    await ingress?.stop?.();
  };

  return state;
}

// The runtime bootstrap is shipped inside the App bundle while the active DSH
// profile contains a separately installed copy of this package. Both copies
// run in one Node process and must observe exactly one generation/policy state.
// A global symbol keeps the state shared without putting credentials in argv,
// environment variables, or an on-disk file.
const ACCESS_STATE_KEY = Symbol.for("dsh.desktop.access-state");
export const accessState = globalThis[ACCESS_STATE_KEY] ?? (globalThis[ACCESS_STATE_KEY] = createAccessState({
  managedLaunch: process.env.DSH_DESKTOP_LAUNCH === "1",
  port: Number(process.env.DSH_DESKTOP_PORT ?? 3080),
}));
