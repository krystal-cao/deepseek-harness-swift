import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryDirectory = path.join(testDirectory, "..");
const recoveryViewModelPath = path.join(repositoryDirectory, "Sources", "Recovery", "RecoveryViewModel.swift");
const recoveryViewPath = path.join(repositoryDirectory, "Sources", "Recovery", "RecoveryView.swift");
const mainWindowPath = path.join(repositoryDirectory, "Sources", "MainWindow", "MainWindowController.swift");
const settingsViewModelPath = path.join(repositoryDirectory, "Sources", "SettingsUI", "SettingsViewModel.swift");
const sources = [
  path.join(testDirectory, "..", "Sources", "Service", "DshSecretRedactor.swift"),
  path.join(testDirectory, "..", "Sources", "Diagnostics", "DshDiagnostic.swift"),
  path.join(testDirectory, "..", "Sources", "Diagnostics", "DshDiagnosticExporter.swift"),
  path.join(testDirectory, "..", "Sources", "Plugins", "DshPluginInspector.swift"),
  path.join(testDirectory, "..", "Sources", "Plugins", "DshPluginFailureResolver.swift"),
  path.join(testDirectory, "..", "Sources", "Recovery", "RecoveryViewModel.swift"),
  path.join(testDirectory, "swift-recovery-harness.swift"),
];

test("Recovery UI exposes conservative P03 evidence and fresh execution intent", () => {
  const viewModel = fs.readFileSync(recoveryViewModelPath, "utf8");
  const view = fs.readFileSync(recoveryViewPath, "utf8");
  const mainWindow = fs.readFileSync(mainWindowPath, "utf8");
  const settings = fs.readFileSync(settingsViewModelPath, "utf8");
  const resolver = fs.readFileSync(path.join(repositoryDirectory, "Sources", "Plugins", "DshPluginFailureResolver.swift"), "utf8");
  assert.match(viewModel, /DshPluginFailureResolver\(\)/);
  assert.match(viewModel, /public var isExecutable: Bool \{ true \}/);
  assert.match(viewModel, /snapshot\.context\?\.profile == "desktop"/);
  assert.match(viewModel, /let generationID = snapshot\.context\?\.generationID/);
  assert.match(viewModel, /planToken: candidate\.removalPlan\.token/);
  assert.match(resolver, /已定位/);
  assert.match(resolver, /疑似相关/);
  assert.match(resolver, /无法确定/);
  assert.match(view, /candidate\.resolution\.rawValue/);
  assert.match(view, /移除计划/);
  assert.match(view, /将修改原 desktop Profile/);
  assert.match(view, /仅提供只读定位/);
  assert.match(mainWindow, /handleRecoveryPluginRemoval/);
  assert.match(mainWindow, /stopSafeModeForPluginRemoval/);
  assert.match(mainWindow, /diagnosticStore\.currentContext\?\.generationID == request\.generationID/);
  assert.match(settings, /removePluginFromRecovery/);
  assert.match(settings, /DshPluginOperationCoordinator\.shared\.persistedStatus == \.absent/);
});

test("native recovery keeps the JSON preview visible across model refresh", () => {
  const mainWindow = fs.readFileSync(mainWindowPath, "utf8");
  assert.match(mainWindow, /detailsText\.string = showingDiagnosticPreview/);
  assert.match(mainWindow, /viewModel\.diagnosticPreview \?\? viewModel\.redactedDetails/);
  assert.match(mainWindow, /if showingDiagnosticPreview \{\s*detailsScroll\.isHidden = false/s);
});

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
