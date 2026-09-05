import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const fixtureDirectory = path.join(testDirectory, 'fixtures', 'plugin-operation')
const sources = [
  path.join(repositoryDirectory, 'Sources', 'State', 'DshState.swift'),
  path.join(repositoryDirectory, 'Sources', 'Versions', 'DshSemanticVersion.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'NodeRuntime.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshLaunchContext.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshSecretRedactor.swift'),
  path.join(repositoryDirectory, 'Sources', 'Versions', 'DshVersionManager.swift'),
  path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginOperationState.swift'),
  path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginManager.swift'),
  path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginOperationCoordinator.swift'),
  path.join(testDirectory, 'swift-plugin-product-chain-harness.swift'),
]

function run(binaryPath, root, scenario) {
  const result = spawnSync(binaryPath, [scenario], {
    env: {
      ...process.env,
      DSH_HOME: path.join(root, 'dsh-home'),
      DSH_TEST_APP_SUPPORT: path.join(root, 'app-support'),
      DSH_PLUGIN_FIXTURE_ROOT: fixtureDirectory,
      DSH_FAKE_PNPM_GLOBAL_CONFIG: path.join(root, 'global-pnpm-config'),
      DSH_FAKE_PNPM_LOG: path.join(root, 'fake-pnpm.log'),
      DSH_FAKE_PNPM_MODE: scenario === 'batch-failure' ? 'fail-update-all' : [
        'minimum-release-age',
        'update-minimum-release-age',
        'update-all-minimum-release-age',
        'update-preflight',
      'update-preflight-confirm',
      'update-preflight-symlink',
    ].includes(scenario) ? 'minimum-release-age'
        : ['silent-update-minimum-release-age', 'silent-update-preflight'].includes(scenario) ? 'silent-minimum-release-age'
          : scenario === 'silent-no-keyword-preflight' ? 'silent-no-keyword'
          : '',
    },
    encoding: 'utf8',
    timeout: 30000,
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
  assert.match(result.stdout, new RegExp(`plugin product-chain ${scenario === 'product-chain' ? 'success' : scenario} passed`))
}

test('P01 isolated product chain executes real manager mutations and rollback', () => {
  const moduleCachePath = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-plugin-product-chain-cache-'))
  const binaryPath = path.join(moduleCachePath, 'harness')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc', '-D', 'DSH_TESTING', '-module-cache-path', moduleCachePath,
      ...sources, '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)
    // NodeRuntime resolves development assets relative to the harness
    // executable, so install the fake pnpm beside this compiled binary.
    const fakePnpm = path.join(moduleCachePath, 'assets', 'bin', 'pnpm')
    fs.mkdirSync(path.dirname(fakePnpm), { recursive: true })
    fs.copyFileSync(path.join(fixtureDirectory, 'fake-pnpm.mjs'), fakePnpm)
    fs.chmodSync(fakePnpm, 0o755)

    for (const scenario of [
      'product-chain',
      'health-failure',
      'batch-failure',
      'safety-gates',
      'minimum-release-age',
      'update-minimum-release-age',
      'update-all-minimum-release-age',
      'update-preflight',
      'update-preflight-confirm',
      'update-preflight-symlink',
      'silent-update-preflight',
      'silent-no-keyword-preflight',
      'silent-update-minimum-release-age',
    ]) {
      const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-plugin-product-chain-'))
      try {
        assertRun(binaryPath, root, scenario)
      } finally {
        fs.rmSync(root, { recursive: true, force: true })
      }
    }
  } finally {
    fs.rmSync(moduleCachePath, { recursive: true, force: true })
  }
})
