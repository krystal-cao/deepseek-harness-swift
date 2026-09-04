import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectDirectory = path.join(testDirectory, "..");
const manifestPath = path.join(testDirectory, "fixtures", "recovery-baseline", "manifest.json");
const webKitHarnessSource = path.join(testDirectory, "swift-wkwebview-acceptance-harness.swift");

function readManifest() {
  return JSON.parse(fs.readFileSync(manifestPath, "utf8"));
}

function materializeCase(root, item) {
  const dshHome = path.join(root, "dsh-home");
  const appSupport = path.join(root, "application-support");
  const profileDirectory = path.join(dshHome, "profiles", item.profile);
  const stateDirectory = path.join(appSupport, "DSH");
  fs.mkdirSync(profileDirectory, { recursive: true });
  fs.mkdirSync(stateDirectory, { recursive: true });

  for (const [relativePath, contents] of Object.entries(item.profileFiles ?? {})) {
    const destination = path.join(profileDirectory, relativePath);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, contents, "utf8");
  }
  for (const [relativePath, contents] of Object.entries(item.stateFiles ?? {})) {
    const destination = path.join(stateDirectory, relativePath);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, contents, "utf8");
  }
  return { dshHome, appSupport, profileDirectory, stateDirectory };
}

function treeBytes(root) {
  const entries = [];
  if (!fs.existsSync(root)) return entries;
  const walk = (directory, prefix = "") => {
    for (const name of fs.readdirSync(directory).sort()) {
      const relative = path.join(prefix, name);
      const absolute = path.join(directory, name);
      const stat = fs.lstatSync(absolute);
      if (stat.isDirectory()) {
        walk(absolute, relative);
      } else if (stat.isFile()) {
        entries.push([relative, fs.readFileSync(absolute)]);
      } else {
        entries.push([relative, Buffer.from(`special:${stat.mode}`)]);
      }
    }
  };
  walk(root);
  return entries;
}

function expectedOutcome(item) {
  if (!item.failure) {
    return { stage: item.expected.stage, errorCode: null };
  }
  return { stage: item.failure.stage, errorCode: item.failure.errorCode };
}

function startFixtureServer() {
  const server = http.createServer((request, response) => {
    const route = new URL(request.url, "http://127.0.0.1").pathname;
    const pages = {
      "/desktop": ["desktop", "桌面 Profile ready"],
      "/web": ["web", "共享 web Profile ready"],
      "/chat-text": ["desktop", "PORT_IN_USE FRONTEND_LOAD_FAILED 这些只是聊天文本，不是启动故障"],
    };
    const page = pages[route];
    if (!page) {
      response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      response.end("not found");
      return;
    }
    const [profile, text] = page;
    const html = `<!doctype html><html><body data-profile="${profile}" data-dsh-ready="true"><main>${text}</main></body></html>`;
    response.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Length": Buffer.byteLength(html),
    });
    response.end(html);
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", reject);
      const address = server.address();
      assert.equal(typeof address, "object");
      resolve({ server, port: address.port });
    });
  });
}

async function reserveClosedPort() {
  const holder = http.createServer();
  await new Promise((resolve, reject) => {
    holder.once("error", reject);
    holder.listen(0, "127.0.0.1", resolve);
  });
  const address = holder.address();
  assert.equal(typeof address, "object");
  const port = address.port;
  await new Promise((resolve) => holder.close(resolve));
  return port;
}

function runProcess(binaryPath, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, args, options);
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

test("F07 materializes every F00 case under isolated DSH_HOME and Application Support", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-f07-fixtures-"));
  try {
    const manifest = readManifest();
    assert.equal(manifest.cases.length, 7);
    const seen = new Set();
    for (const item of manifest.cases) {
      const caseRoot = path.join(root, item.id);
      const locations = materializeCase(caseRoot, item);
      assert.ok(locations.dshHome.startsWith(root + path.sep));
      assert.ok(locations.appSupport.startsWith(root + path.sep));
      assert.notEqual(locations.dshHome, locations.appSupport);
      assert.equal(fs.readFileSync(path.join(locations.stateDirectory, "dsh-state.json"), "utf8"), item.stateFiles["dsh-state.json"]);

      const before = treeBytes(caseRoot);
      const outcome = expectedOutcome(item);
      assert.equal(outcome.stage, item.expected.stage, item.id);
      if (item.failure) assert.equal(outcome.errorCode, item.failure.errorCode, item.id);
      for (const [relativePath, contents] of Object.entries(item.profileFiles ?? {})) {
        const target = path.join(locations.profileDirectory, relativePath);
        assert.equal(fs.readFileSync(target, "utf8"), contents, `${item.id}/${relativePath}`);
      }
      assert.deepEqual(treeBytes(caseRoot), before, `${item.id} fixture changed during read-only acceptance`);
      seen.add(item.id);
    }
    assert.deepEqual([...seen].sort(), manifest.cases.map((item) => item.id).sort());
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("F07 real macOS WKWebView covers desktop, web, inert chat error text, and native recovery", { skip: process.env.DSH_F07_WKWEBVIEW !== "1" ? "set DSH_F07_WKWEBVIEW=1 to run the real macOS harness" : false }, async () => {
  assert.equal(process.platform, "darwin", "the real harness requires macOS WebKit");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-f07-wkwebview-"));
  const fixture = await startFixtureServer();
  const failurePort = await reserveClosedPort();
  const binaryPath = path.join(root, "wkwebview-harness");
  const moduleCachePath = path.join(root, "module-cache");
  const tempDirectory = path.join(root, "tmp");
  const dshHome = path.join(root, "dsh-home");
  const appSupport = path.join(root, "application-support");
  fs.mkdirSync(tempDirectory, { recursive: true });
  fs.mkdirSync(dshHome, { recursive: true });
  fs.mkdirSync(appSupport, { recursive: true });
  const profileMarker = path.join(dshHome, "profiles", "desktop", "f07-profile-marker");
  const stateMarker = path.join(appSupport, "DSH", "f07-state-marker");
  fs.mkdirSync(path.dirname(profileMarker), { recursive: true });
  fs.mkdirSync(path.dirname(stateMarker), { recursive: true });
  fs.writeFileSync(profileMarker, "desktop-fixture\n", "utf8");
  fs.writeFileSync(stateMarker, "state-fixture\n", "utf8");
  const profileBefore = treeBytes(dshHome);
  const appSupportBefore = treeBytes(appSupport);
  try {
    const compile = spawnSync("xcrun", [
      "swiftc",
      "-parse-as-library",
      "-module-cache-path", moduleCachePath,
      webKitHarnessSource,
      "-framework", "AppKit",
      "-framework", "WebKit",
      "-o", binaryPath,
    ], { encoding: "utf8", timeout: 120000 });
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);

    const baseURL = `http://127.0.0.1:${fixture.port}`;
    const run = await runProcess(binaryPath, [
      `${baseURL}/desktop`,
      `${baseURL}/web`,
      `${baseURL}/chat-text`,
      `http://127.0.0.1:${failurePort}/frontend-failure`,
    ], {
      env: {
        ...process.env,
        DSH_HOME: dshHome,
        DSH_TEST_APP_SUPPORT: appSupport,
        TMPDIR: tempDirectory,
      },
      encoding: "utf8",
      timeout: 30000,
    });
    assert.equal(run.code, 0, `${run.stderr}\n${run.stdout}`);
    assert.match(run.stdout, /wkwebview ready step=desktop profile=desktop/);
    assert.match(run.stdout, /wkwebview ready step=web profile=web/);
    assert.match(run.stdout, /wkwebview chat-text remained ready despite inert failure words/);
    assert.match(run.stdout, /wkwebview recovery-visible phase=loadingInterface code=pageLoadFailed/);
    assert.match(run.stdout, /swift wkwebview acceptance harness passed/);
    assert.deepEqual(treeBytes(dshHome), profileBefore, "desktop fixture changed during WebKit acceptance");
    assert.deepEqual(treeBytes(appSupport), appSupportBefore, "test Application Support changed during WebKit acceptance");
  } finally {
    await new Promise((resolve) => fixture.server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("F07 force-exit fixture keeps all persisted recovery boundaries explicit", () => {
  const fixturePath = path.join(testDirectory, "fixtures", "recovery-profile", "force-exit-phases.json");
  const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8"));
  assert.deepEqual(fixture.phases.map((phase) => phase.phase), ["entered", "launched", "cleanupPending", "cleaned"]);
  for (const phase of fixture.phases) {
    assert.match(phase.interruptAfter, /state-record-write|recovery-service-start|profile-tree-removal|cleaned-record-write/);
    assert.match(phase.expected, /record|isolated|cleanup|stale/);
  }
});
