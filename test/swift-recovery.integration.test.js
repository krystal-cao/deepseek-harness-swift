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
  path.join(testDirectory, "..", "Sources", "Recovery", "RecoveryViewModel.swift"),
  path.join(testDirectory, "swift-recovery-harness.swift"),
];

test("Swift recovery view model filters launches and guards explicit actions", () => {
  const binaryPath = path.join(os.tmpdir(), `dsh-recovery-${process.pid}`);
  const moduleCachePath = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-recovery-module-cache-"));
  try {
    const compile = spawnSync("xcrun", ["swiftc", ...sources, "-module-cache-path", moduleCachePath, "-o", binaryPath], {
      encoding: "utf8",
      timeout: 120000,
    });
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);
    const run = spawnSync(binaryPath, [], { encoding: "utf8", timeout: 30000 });
    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /swift recovery harness passed/);
  } finally {
    try { fs.unlinkSync(binaryPath); } catch { /* no binary after failed compile */ }
    fs.rmSync(moduleCachePath, { recursive: true, force: true });
  }
});
