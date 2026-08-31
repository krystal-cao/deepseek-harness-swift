import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { createUpstreamAuthFixture } from "./fixtures/upstream-auth/server.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sources = [
  path.join(testDirectory, "..", "Sources", "Service", "DshRuntimeHealthClient.swift"),
  path.join(testDirectory, "swift-runtime-health-harness.swift"),
];

function run(binaryPath, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, args, { encoding: "utf8" });
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

test("Swift runtime health client uses explicit credentials and bounded redirects", async (t) => {
  const fixture = await createUpstreamAuthFixture({ mode: "alpha" });
  t.after(() => fixture.close());

  const binaryPath = path.join(os.tmpdir(), "dsh-runtime-health-" + process.pid);
  try {
    const compile = spawnSync("xcrun", [
      "swiftc",
      ...sources,
      "-module-cache-path",
      path.join(os.tmpdir(), "dsh-alpha2-module-cache"),
      "-o",
      binaryPath,
    ], {
      encoding: "utf8",
      timeout: 120000,
    });
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);

    const result = await run(binaryPath, [String(fixture.port), fixture.cookieName]);
    assert.equal(result.code, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /swift runtime health client harness passed/);
  } finally {
    try { fs.unlinkSync(binaryPath); } catch { /* no binary after failed compile */ }
  }
});
