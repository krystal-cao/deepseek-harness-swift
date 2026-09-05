import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const coordinatorPath = path.join(
  repositoryDirectory, 'Sources', 'Plugins', 'DshPluginOperationCoordinator.swift'
)
const statePath = path.join(
  repositoryDirectory, 'Sources', 'Plugins', 'DshPluginOperationState.swift'
)
const sources = [
  path.join(repositoryDirectory, 'Sources', 'State', 'DshState.swift'),
  path.join(repositoryDirectory, 'Sources', 'Versions', 'DshSemanticVersion.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'NodeRuntime.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshLaunchContext.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshSecretRedactor.swift'),
  path.join(repositoryDirectory, 'Sources', 'Versions', 'DshVersionManager.swift'),
  statePath,
  path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginManager.swift'),
  coordinatorPath,
  path.join(testDirectory, 'swift-plugin-operation-harness.swift'),
]

function run(binaryPath, root, scenario) {
  const result = spawnSync(binaryPath, [scenario], {
    env: {
      ...process.env,
      // Every invocation gets an explicit temporary home and Application
      // Support root. The second invocation in a pair is the restart.
      DSH_HOME: path.join(root, 'dsh-home'),
      DSH_TEST_APP_SUPPORT: path.join(root, 'app-support'),
    },
    encoding: 'utf8',
    timeout: 15000,
  })
  return result
}

function assertRun(binaryPath, root, scenario) {
  const result = run(binaryPath, root, scenario)
  assert.equal(
    result.status,
    0,
    `${scenario} failed (status ${result.status})\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
  )
  assert.match(result.stdout, new RegExp(`plugin operation scenario ${scenario} passed`))
}

function runAcrossRestart(binaryPath, setupScenario, recoverScenario) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-plugin-operation-test-'))
  try {
    assertRun(binaryPath, root, setupScenario)
    assertRun(binaryPath, root, recoverScenario)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
}

function runSingle(binaryPath, scenario) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-plugin-operation-test-'))
  try {
    assertRun(binaryPath, root, scenario)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
}

test('P01 restart and rollback matrix stays fail-closed', () => {
  const coordinator = fs.readFileSync(coordinatorPath, 'utf8')
  const state = fs.readFileSync(statePath, 'utf8')
  assert.match(state, /case prepared/) // durable pre-mutation interruption
  assert.match(state, /case mutating/) // package mutation in progress
  assert.match(state, /case verifying/) // post-mutation health window
  assert.match(state, /case committed/) // retained post-commit record
  assert.match(state, /case restoring/) // retryable restoration
  assert.match(state, /case recoveryRequired/) // explicit unresolved recovery
  assert.match(coordinator, /try await hooks\.prepareForMutation\(\)/)
  assert.ok(
    coordinator.indexOf('snapshot = try await pluginManager.createPluginOperationSnapshot(') >
      coordinator.indexOf('try await hooks.prepareForMutation()'),
    'service preparation must precede snapshot creation'
  )

  const moduleCachePath = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-plugin-operation-cache-'))
  const binaryPath = path.join(moduleCachePath, 'harness')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc', '-D', 'DSH_TESTING', '-module-cache-path', moduleCachePath,
      ...sources, '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    // These pairs execute setup and recovery in separate Swift processes,
    // exercising the on-disk operation state as a real restart would.
    runAcrossRestart(binaryPath, 'prepared-setup', 'prepared-recover')
    runAcrossRestart(binaryPath, 'mutating-no-digest-setup', 'mutating-no-digest-recover')
    runAcrossRestart(binaryPath, 'verifying-setup', 'verifying-commit-recover')
    runAcrossRestart(binaryPath, 'verifying-setup', 'verifying-restore-recover')
    runAcrossRestart(binaryPath, 'restoring-setup', 'restoring-recover')
    runAcrossRestart(binaryPath, 'restoring-cleanup-setup', 'restoring-cleanup-recover')
    runAcrossRestart(binaryPath, 'missing-snapshot-setup', 'missing-snapshot-recover')
    runAcrossRestart(binaryPath, 'ownership-mismatch-setup', 'ownership-mismatch-recover')
    runAcrossRestart(binaryPath, 'external-setup', 'external-recover')

    runSingle(binaryPath, 'committed')
    runSingle(binaryPath, 'cancel-before-record')
    runSingle(binaryPath, 'cancel-during-mutation')
    runSingle(binaryPath, 'cancel-during-mutation-recovery-failure')
    runSingle(binaryPath, 'cancel-during-verify')
    runSingle(binaryPath, 'capacity-contract')
    runSingle(binaryPath, 'owned-snapshot-delete-guard')
    runSingle(binaryPath, 'batch-failure')
    runSingle(binaryPath, 'corrupt-record')
    runSingle(binaryPath, 'structurally-invalid-record')
  } finally {
    fs.rmSync(moduleCachePath, { recursive: true, force: true })
  }
})
