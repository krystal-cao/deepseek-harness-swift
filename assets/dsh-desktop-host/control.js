import { accessState, isValidGeneration, NETWORK_EXPOSURES } from "./access-state.js";
import { isAbsolute } from "node:path";

const PROTOCOL_VERSION = 1;
const MAX_LINE_BYTES = 16 * 1024;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/u;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const SUPPORTED_PROFILES = new Set(["desktop", "web"]);

let started = false;
let controlReadyAnnounced = false;
let resolveBootstrap;
let rejectBootstrap;
let controlQueue = Promise.resolve();
let failurePromise;
const bootstrapPromise = new Promise((resolve, reject) => {
  resolveBootstrap = resolve;
  rejectBootstrap = reject;
});

function protocolFailure(reason) {
  if (failurePromise) return failurePromise;
  failurePromise = (async () => {
    try {
      await accessState.shutdownControlledAccess?.();
    } catch (error) {
      process.stderr.write(`dsh desktop access cleanup failed: ${error instanceof Error ? error.message : String(error)}\n`);
    }
    rejectBootstrap(new Error(reason));
    process.stderr.write(`dsh desktop control failed: ${reason}\n`);
    process.exitCode = 1;
    process.nextTick(() => process.exit(1));
  })();
  return failurePromise;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validateGeneration(message) {
  if (!isObject(message) || message.v !== PROTOCOL_VERSION || message.type !== "generation") throw new Error("invalid generation message");
  if (typeof message.generation !== "string" || !UUID_PATTERN.test(message.generation)) throw new Error("invalid generation id");
  if (typeof message.rendererToken !== "string" || !TOKEN_PATTERN.test(message.rendererToken)) throw new Error("invalid renderer token");
  if (typeof message.ordinaryBrowserEnabled !== "boolean") throw new Error("invalid browser policy");
  if (!Object.values(NETWORK_EXPOSURES).includes(message.networkExposure) || (message.networkExposure === NETWORK_EXPOSURES.lan && !message.ordinaryBrowserEnabled)) throw new Error("invalid network exposure");
  return message;
}

function validatePolicy(message) {
  if (!isObject(message) || message.v !== PROTOCOL_VERSION || message.type !== "policy") throw new Error("invalid policy message");
  if (typeof message.generation !== "string" || !isValidGeneration(message.generation)) throw new Error("invalid policy generation");
  if (!Number.isSafeInteger(message.revision) || message.revision < 1) throw new Error("invalid policy revision");
  if (typeof message.ordinaryBrowserEnabled !== "boolean") throw new Error("invalid browser policy");
  if (!Object.values(NETWORK_EXPOSURES).includes(message.networkExposure) || (message.networkExposure === NETWORK_EXPOSURES.lan && !message.ordinaryBrowserEnabled)) throw new Error("invalid policy network exposure");
  return message;
}

function validateBootstrap(message) {
  if (!isObject(message) || message.v !== PROTOCOL_VERSION || message.type !== "bootstrap") throw new Error("invalid bootstrap message");
  if (typeof message.entryPath !== "string" || !isAbsolute(message.entryPath) || message.entryPath.includes("\0")) throw new Error("invalid bootstrap entry path");
  if (typeof message.profile !== "string" || !SUPPORTED_PROFILES.has(message.profile)) throw new Error("invalid bootstrap profile");
  if (message.host !== "127.0.0.1") throw new Error("invalid bootstrap host");
  if (!Number.isSafeInteger(message.port) || message.port < 1024 || message.port > 65535) throw new Error("invalid bootstrap port");
  if (!isValidGeneration(message.generation)) throw new Error("invalid bootstrap generation");
  if (typeof message.rendererToken !== "string" || !TOKEN_PATTERN.test(message.rendererToken)) throw new Error("invalid bootstrap renderer token");
  if (typeof message.ordinaryBrowserEnabled !== "boolean") throw new Error("invalid bootstrap browser policy");
  if (!Object.values(NETWORK_EXPOSURES).includes(message.networkExposure) || (message.networkExposure === NETWORK_EXPOSURES.lan && !message.ordinaryBrowserEnabled)) throw new Error("invalid bootstrap network exposure");
  return message;
}

function writePolicyAck() {
  process.stdout.write(
    `dsh desktop policy applied: ${accessState.generation} ${String(accessState.policyRevision)} ${String(accessState.ordinaryBrowserEnabled)} ${accessState.networkExposure}\n`,
  );
}

async function handleMessage(message) {
  if (!accessState.initialized) {
    if (message?.type === "bootstrap") {
      const bootstrap = validateBootstrap(message);
      accessState.port = bootstrap.port;
      accessState.initializeGeneration(bootstrap);
      resolveBootstrap(bootstrap);
      maybeAnnounceControlReady();
      return;
    }
    const generation = validateGeneration(message);
    accessState.initializeGeneration(generation);
    maybeAnnounceControlReady();
    return;
  }
  const policy = validatePolicy(message);
  const result = await accessState.applyPolicy(policy);
  if (result.changed && !result.ordinaryBrowserEnabled) accessState.closeOrdinarySockets();
  writePolicyAck();
}

function consumeLine(line) {
  const normalized = line.endsWith("\r") ? line.slice(0, -1) : line;
  if (Buffer.byteLength(normalized, "utf8") > MAX_LINE_BYTES) throw new Error("control line too long");
  let message;
  try {
    message = JSON.parse(normalized);
  } catch {
    throw new Error("invalid control JSON");
  }
  return message;
}

function maybeAnnounceControlReady() {
  if (!accessState.managedLaunch || controlReadyAnnounced || !accessState.initialized || !accessState.serverReady) return;
  controlReadyAnnounced = true;
  process.stdout.write(`dsh desktop control ready: ${accessState.generation}\n`);
}

export function startDesktopControl() {
  if (!accessState.managedLaunch || started) return accessState;
  started = true;
  process.stdin.setEncoding("utf8");
  let pending = "";
  const fail = (error) => protocolFailure(error instanceof Error ? error.message : "control stream error");
  process.stdin.on("data", (chunk) => {
    try {
      pending += chunk;
      if (Buffer.byteLength(pending, "utf8") > MAX_LINE_BYTES && !pending.includes("\n")) throw new Error("control line too long");
      let newline;
      while ((newline = pending.indexOf("\n")) !== -1) {
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        const message = consumeLine(line);
        controlQueue = controlQueue.then(() => handleMessage(message)).catch(fail);
      }
      if (Buffer.byteLength(pending, "utf8") > MAX_LINE_BYTES) throw new Error("control line too long");
    } catch (error) {
      process.stdin.pause();
      fail(error);
    }
  });
  process.stdin.on("end", () => {
    controlQueue.then(() => {
      if (pending.length > 0) {
        return protocolFailure("control stream closed with an incomplete message");
      }
      return protocolFailure(
        accessState.initialized
          ? "control stream closed"
          : "control stream closed before generation",
      );
    }).catch(fail);
  });
  process.stdin.on("error", fail);
  process.stdin.resume();
  return accessState;
}

export function waitForDesktopBootstrap() {
  if (!accessState.managedLaunch) return Promise.reject(new Error("desktop bootstrap requires a managed launch"));
  startDesktopControl();
  return bootstrapPromise;
}

export function markDesktopServerReady() {
  accessState.markServerReady();
  maybeAnnounceControlReady();
}

export { MAX_LINE_BYTES, PROTOCOL_VERSION };
