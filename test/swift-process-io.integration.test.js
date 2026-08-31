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
  path.join(testDirectory, "..", "Sources", "Service", "DshWebEndpoint.swift"),
  path.join(testDirectory, "..", "Sources", "Service", "DshSecretRedactor.swift"),
  path.join(testDirectory, "..", "Sources", "Service", "DshProcessIO.swift"),
  path.join(testDirectory, "swift-process-io-harness.swift"),
];

test("Swift ProcessIO preserves alpha bootstrap URLs and redacts diagnostics", () => {
  const binaryPath = path.join(os.tmpdir(), `dsh-process-io-${process.pid}`);
  try {
    const compile = spawnSync("xcrun", ["swiftc", ...sources, "-o", binaryPath], {
      encoding: "utf8",
      timeout: 120000,
    });
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);

    const run = spawnSync(binaryPath, [], { encoding: "utf8", timeout: 10000 });
    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /endpoint and redaction harness passed/);
  } finally {
    try { fs.unlinkSync(binaryPath); } catch { /* no binary after failed compile */ }
  }
});

test("Swift ProcessIO rejects a conflicting second ready URL", () => {
  const binaryPath = path.join(os.tmpdir(), `dsh-process-io-conflict-${process.pid}`);
  try {
    const compile = spawnSync("xcrun", ["swiftc", ...sources, "-o", binaryPath], {
      encoding: "utf8",
      timeout: 120000,
    });
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);

    const run = spawnSync(binaryPath, ["--conflict", "--late-wait"], { encoding: "utf8", timeout: 10000 });
    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /endpoint and redaction harness passed/);
  } finally {
    try { fs.unlinkSync(binaryPath); } catch { /* no binary after failed compile */ }
  }
});

test("DshWebEndpoint applies the strict origin and query contract", () => {
  const endpointSource = fs.readFileSync(path.join(testDirectory, "..", "Sources", "Service", "DshWebEndpoint.swift"), "utf8");
  assert.match(endpointSource, /expectedPort/);
  assert.match(endpointSource, /components\.host == "127\.0\.0\.1"/);
  assert.match(endpointSource, /components\.user == nil, components\.password == nil/);
  assert.match(endpointSource, /item\.name == "token"/);
  assert.match(endpointSource, /queryItems\.count == 1/);
});
