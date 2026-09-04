import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sources = [
  path.join(testDirectory, "..", "Sources", "State", "DshState.swift"),
  path.join(testDirectory, "..", "Sources", "Versions", "DshSemanticVersion.swift"),
  path.join(testDirectory, "..", "Sources", "Service", "NodeRuntime.swift"),
  path.join(testDirectory, "..", "Sources", "Versions", "DshVersionManager.swift"),
  path.join(testDirectory, "..", "Sources", "Service", "DshLaunchContext.swift"),
  path.join(testDirectory, "..", "Sources", "Recovery", "DshRecoveryState.swift"),
  path.join(testDirectory, "..", "Sources", "Recovery", "DshRecoveryProfileManager.swift"),
  path.join(testDirectory, "swift-recovery-profile-harness.swift"),
];

test("Swift recovery Profile manager isolates files, persists interruption state, and cleans safely", () => {
  const binaryPath = path.join(os.tmpdir(), `dsh-recovery-profile-${process.pid}`);
  const moduleCachePath = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-recovery-profile-module-cache-"));
  try {
    const compile = spawnSync("xcrun", ["swiftc", ...sources, "-module-cache-path", moduleCachePath, "-o", binaryPath], {
      encoding: "utf8",
      timeout: 120000,
    });
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);
    const run = spawnSync(binaryPath, [], { encoding: "utf8", timeout: 30000 });
    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /swift recovery profile harness passed/);
  } finally {
    try { fs.unlinkSync(binaryPath); } catch { /* no binary after failed compile */ }
    fs.rmSync(moduleCachePath, { recursive: true, force: true });
  }
});
