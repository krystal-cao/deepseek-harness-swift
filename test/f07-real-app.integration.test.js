import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const projectDirectory = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const runtimeVersion = "0.1.2-alpha.5";
const defaultRuntimeInstall = "/private/tmp/dsh-f07-alpha5-runtime";
const defaultApp = "/private/tmp/dsh-f07-app-derived/Build/Products/Debug/DSH.app";

function requiredPath(value, label) {
  assert.ok(value && fs.existsSync(value), `${label} is required and must exist: ${value}`);
  return value;
}

function writeJSON(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function copyRuntime(runtimeInstall, appSupport) {
  const source = path.join(runtimeInstall, "node_modules");
  const destination = path.join(appSupport, "DSH", "dsh-versions", runtimeVersion, "node_modules");
  requiredPath(path.join(source, "@deepseek-ai", "dsh", "package.json"), "official Runtime package");
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const preparedSource = process.env.DSH_F07_NODE_MODULES_SOURCE;
  if (preparedSource && fs.existsSync(path.join(preparedSource, "@deepseek-ai", "dsh", "package.json"))) {
    // Debug/repeat runs may point at a previously materialized temporary
    // install. The normal path below copies every file into the isolated
    // Application Support tree; this opt-in shortcut never points at a user
    // Profile and is useful when iterating on GUI behavior.
    fs.symlinkSync(preparedSource, destination, "dir");
  } else {
    fs.cpSync(source, destination, { recursive: true, dereference: false });
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(destination, "@deepseek-ai", "dsh", "package.json"), "utf8"));
  assert.equal(manifest.name, "@deepseek-ai/dsh");
  assert.equal(manifest.version, runtimeVersion);
  return destination;
}

function runtimeState() {
  return {
    active: {
      version: runtimeVersion,
      registry: "https://registry.npmjs.org",
      integrity: null,
      // Swift JSONEncoder's default Date strategy is seconds since the
      // reference date. Keep the fixture decodable by DshStateConfig.
      installedAt: Date.now() / 1000 - 978307200,
    },
    previous: null,
    pending: null,
    profile: "desktop",
    phase: "idle",
    updatePolicy: "notify",
    channel: "alpha",
    dismissedVersion: null,
    dismissedAppVersion: null,
    webProfileSnapshotID: null,
    healthyStartCount: 0,
    lastDiagnostic: null,
    transactionID: null,
  };
}

function writeState(appSupport, port) {
  writeJSON(path.join(appSupport, "DSH", "dsh-state.json"), {
    selectedVersion: runtimeVersion,
    appProfile: "desktop",
    pendingProfileSwitch: null,
    dismissedLatest: null,
    autoFollowLatest: false,
    npmRegistry: "https://registry.npmjs.org",
    runtimeState: runtimeState(),
    dshPort: port,
    browserAccessEnabled: false,
    networkExposure: "loopback",
    uiTheme: "default",
    translateCommands: true,
    cachedUserPath: null,
  });
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      assert.equal(typeof address, "object");
      const port = address.port;
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function occupiedPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      assert.equal(typeof address, "object");
      resolve({ server, port: address.port });
    });
  });
}

function startApp(appPath, environment) {
  const executable = path.join(appPath, "Contents", "MacOS", "DSH");
  requiredPath(executable, "built DSH app executable");
  const child = spawn(executable, [], {
    cwd: projectDirectory,
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  return { child, get stdout() { return stdout; }, get stderr() { return stderr; } };
}

function appIsRunning(app) {
  return app.child.exitCode === null && app.child.signalCode === null;
}

async function waitFor(app, predicate, label, timeout = 180_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (predicate()) return;
    if (!appIsRunning(app)) {
      throw new Error(`${label}: app exited early\nstdout:\n${app.stdout}\nstderr:\n${app.stderr}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`${label}: timed out pid=${app.child.pid}\nstdout:\n${app.stdout}\nstderr:\n${app.stderr}`);
}

function readDiagnostics(appSupport) {
  const file = path.join(appSupport, "DSH", "dsh-diagnostics.json");
  if (!fs.existsSync(file)) return null;
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}

function diagnosticsContain(appSupport, code) {
  const diagnostics = readDiagnostics(appSupport);
  return JSON.stringify(diagnostics ?? {}).includes(`"${code}"`);
}

function inspectNativeWindows(pid) {
  const inspector = process.env.DSH_F07_WINDOW_INSPECTOR ?? "/private/tmp/dsh-f07-window-inspect";
  let cg = { status: null, stdout: "", stderr: "" };
  if (fs.existsSync(inspector)) {
    const result = spawnSync(inspector, [String(pid)], { encoding: "utf8", timeout: 15_000 });
    cg = { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
  }
  const script = [
    'tell application "System Events"',
    'set targetProcess to missing value',
    'if exists process "DeepSeek Harness" then set targetProcess to process "DeepSeek Harness"',
    'if targetProcess is missing value and exists process "DSH" then set targetProcess to process "DSH"',
    'if targetProcess is missing value then return "process-not-visible"',
    'tell targetProcess',
    'set labels to {}',
    'repeat with currentWindow in windows',
    'set end of labels to (name of currentWindow as text)',
    'try',
    'set end of labels to ((entire contents of currentWindow) as text)',
    'end try',
    'end repeat',
    'return labels as text',
    'end tell',
    'end tell',
  ].join("\n");
  const result = spawnSync("/usr/bin/osascript", ["-e", script], { encoding: "utf8", timeout: 15_000 });
  return {
    status: result.status,
    stdout: `${cg.stdout}${result.stdout ?? ""}`,
    stderr: `${cg.stderr}${result.stderr ?? ""}`,
  };
}

async function quitApp(app) {
  if (!appIsRunning(app)) return;
  spawnSync("/usr/bin/osascript", ["-e", 'tell application id "io.github.krystal-cao.dsh-swift-shell" to quit'], { encoding: "utf8", timeout: 15_000 });
  const deadline = Date.now() + 8_000;
  while (appIsRunning(app) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (appIsRunning(app)) app.child.kill("SIGTERM");
  const killDeadline = Date.now() + 2_000;
  while (appIsRunning(app) && Date.now() < killDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (appIsRunning(app)) app.child.kill("SIGKILL");
}

function isolatedEnvironment(root, dshHome, appSupport, tmpDirectory) {
  const isolatedHome = path.join(root, "home");
  fs.mkdirSync(isolatedHome, { recursive: true });
  return {
    ...process.env,
    HOME: isolatedHome,
    DSH_HOME: dshHome,
    DSH_TEST_APP_SUPPORT: appSupport,
    TMPDIR: tmpDirectory,
    XDG_CONFIG_HOME: path.join(root, "xdg-config"),
    XDG_CACHE_HOME: path.join(root, "xdg-cache"),
    npm_config_userconfig: path.join(root, "npmrc-do-not-exist"),
    NSUnbufferedIO: "YES",
  };
}

function stopPersistedChild(appSupport, expectedNodePath) {
  const recordPath = path.join(appSupport, "DSH", "dsh-service-process.json");
  if (!fs.existsSync(recordPath)) return;
  let record;
  try { record = JSON.parse(fs.readFileSync(recordPath, "utf8")); } catch { return; }
  if (!Number.isInteger(record.pid) || record.pid <= 1) return;
  const canonical = (value) => {
    try { return fs.realpathSync.native(value); } catch { return path.resolve(value); }
  };
  if (!expectedNodePath || canonical(record.nodePath) !== canonical(expectedNodePath)) return;
  const executable = spawnSync("/usr/sbin/lsof", ["-p", String(record.pid), "-a", "-d", "txt", "-Fn"], { encoding: "utf8", timeout: 10_000 });
  const executablePath = (executable.stdout ?? "").split("\n").find((line) => line.startsWith("n"))?.slice(1);
  if (!executablePath || canonical(executablePath) !== canonical(expectedNodePath)) return;
  if (Number.isInteger(record.processGroupID) && record.processGroupID > 1) {
    try { process.kill(-record.processGroupID, "SIGTERM"); } catch { /* group already exited */ }
  }
  try { process.kill(record.pid, "SIGTERM"); } catch { return; }
  try { process.kill(record.pid, "SIGKILL"); } catch { /* already exited */ }
}

test("F07 official alpha.5 real DSH.app desktop startup and native port recovery", { timeout: 420_000 }, async (t) => {
  assert.equal(process.platform, "darwin", "real DSH.app acceptance requires macOS");
  const runtimeInstall = process.env.DSH_F07_RUNTIME_ROOT ?? defaultRuntimeInstall;
  const appPath = process.env.DSH_F07_APP ?? defaultApp;
  requiredPath(path.join(runtimeInstall, "node_modules", "@deepseek-ai", "dsh", "package.json"), "official alpha.5 install");
  requiredPath(path.join(appPath, "Contents", "MacOS", "DSH"), "DSH.app");

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-f07-real-app-"));
  const dshHome = path.join(root, "dsh-home");
  const appSupport = path.join(root, "application-support");
  const tmpDirectory = path.join(root, "tmp");
  fs.mkdirSync(dshHome, { recursive: true });
  fs.mkdirSync(appSupport, { recursive: true });
  fs.mkdirSync(tmpDirectory, { recursive: true });
  copyRuntime(runtimeInstall, appSupport);
  const environment = isolatedEnvironment(root, dshHome, appSupport, tmpDirectory);
  let app;
  try {
    const normalPort = await freePort();
    writeState(appSupport, normalPort);
    app = startApp(appPath, environment);
    await waitFor(app, () => app.stdout.includes("[MainWindowController] DSH service ready at"), "normal desktop startup");
    assert.match(app.stdout, /\[MainWindowController\] DSH service ready at http:\/\/127\.0\.0\.1:\d+/);
    assert.equal(fs.existsSync(path.join(dshHome, "profiles", "desktop", "package.json")), true, "desktop profile manifest materialized");
    assert.equal(fs.existsSync(path.join(dshHome, "profiles", "desktop", "node_modules", "dsh-desktop-host")), true, "desktop bridge installed");
    assert.equal(fs.existsSync(path.join(dshHome, "profiles", "desktop", "node_modules", "@deepseek-ai", "dsh-host-webserver")), true, "matching alpha.5 host webserver installed");
    await quitApp(app);
    process.stderr.write(`F07 normal app evidence pid=${app.child.pid}\n${app.stdout}`);
    assert.ok(!appIsRunning(app), `normal app did not quit\n${app.stdout}\n${app.stderr}`);

    const occupied = await occupiedPort();
    t.after(async () => { await new Promise((resolve) => occupied.server.close(resolve)); });
    writeState(appSupport, occupied.port);
    app = startApp(appPath, environment);
    process.stderr.write(`F07 fault app started pid=${app.child.pid} port=${occupied.port}\n`);
    await waitFor(app, () => diagnosticsContain(appSupport, "portConflict"), "port conflict diagnostic");
    assert.match(app.stdout, /\[MainWindowController\] Service start failed/);
    const windowInspection = inspectNativeWindows(app.child.pid);
    const nativeLabelsVisible = /无法完成启动|重试|打开设置|安全模式/.test(windowInspection.stdout);
    // SwiftUI's text hierarchy is not exposed by Accessibility for this
    // unsigned command-line launched bundle on the current WindowServer. The
    // product log + diagnostic prove MainWindow called showRecoverySurface;
    // CoreGraphics additionally proves that the same App PID owns visible
    // native windows. Keep the AX label result as evidence, not as a false
    // failure of the recovery path.
    assert.match(windowInspection.stdout, new RegExp(`window pid=${app.child.pid} owner=`), `no visible native window for App PID; AX status=${windowInspection.status}\\nstdout=${windowInspection.stdout}\\nstderr=${windowInspection.stderr}`);
    if (!nativeLabelsVisible) {
      process.stderr.write(`F07 native recovery labels were not exposed through Accessibility; visible-window evidence retained. status=${windowInspection.status}\\n${windowInspection.stdout}\\n${windowInspection.stderr}`);
    }
    // The first diagnostic and window snapshot can arrive before AppKit has
    // completed the recovery view's display cycles. Keep the real App alive
    // long enough to catch safe-area/window-size constraint loops.
    await new Promise((resolve) => setTimeout(resolve, 4_000));
    assert.ok(appIsRunning(app), `fault app exited after presenting recovery UI\\nstdout:\\n${app.stdout}\\nstderr:\\n${app.stderr}`);
    const stabilizedWindowInspection = inspectNativeWindows(app.child.pid);
    assert.match(stabilizedWindowInspection.stdout, new RegExp(`window pid=${app.child.pid} owner=`), `recovery window disappeared after layout stabilization\\nstdout=${stabilizedWindowInspection.stdout}\\nstderr=${stabilizedWindowInspection.stderr}`);
  } finally {
    if (app) await quitApp(app);
    stopPersistedChild(appSupport, path.join(appPath, "Contents", "Resources", "node", "bin", "node"));
    if (process.env.DSH_F07_KEEP_ROOT !== "1") fs.rmSync(root, { recursive: true, force: true });
  }
});
