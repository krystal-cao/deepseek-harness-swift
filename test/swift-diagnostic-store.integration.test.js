import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sources = [
  path.join(testDirectory, "..", "Sources", "Service", "DshSecretRedactor.swift"),
  path.join(testDirectory, "..", "Sources", "Diagnostics", "DshDiagnostic.swift"),
  path.join(testDirectory, "..", "Sources", "Diagnostics", "DshDiagnosticStore.swift"),
  path.join(testDirectory, "swift-diagnostic-store-harness.swift"),
];

test("Swift diagnostic store filters, redacts, bounds, deduplicates, and persists launch failures", () => {
  const binaryPath = path.join(os.tmpdir(), `dsh-diagnostic-store-${process.pid}`);
  const moduleCachePath = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-diagnostic-module-cache-"));
  try {
    const compile = spawnSync("xcrun", ["swiftc", ...sources, "-module-cache-path", moduleCachePath, "-o", binaryPath], {
      encoding: "utf8",
      timeout: 120000,
    });
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);
    const run = spawnSync(binaryPath, [], { encoding: "utf8", timeout: 30000 });
    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /swift diagnostic store harness passed/);
  } finally {
    try { fs.unlinkSync(binaryPath); } catch { /* no binary after failed compile */ }
    fs.rmSync(moduleCachePath, { recursive: true, force: true });
  }
});
