import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const sources = [
  path.join(repositoryDirectory, 'Sources', 'State', 'DshState.swift'),
  path.join(repositoryDirectory, 'Sources', 'Versions', 'DshSemanticVersion.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'NodeRuntime.swift'),
  path.join(repositoryDirectory, 'Sources', 'Versions', 'DshVersionManager.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshLaunchContext.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshControlProtocol.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshWebEndpoint.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshAccessController.swift'),
  path.join(testDirectory, 'swift-browser-access-live-policy-harness.swift'),
]

test('live browser policy changes only after the matching ACK', () => {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-browser-access-policy-test-'))
  const binaryPath = path.join(testRoot, 'harness')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc', '-D', 'DSH_TESTING', '-module-cache-path', path.join(testRoot, 'module-cache'),
      ...sources, '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    const run = spawnSync(binaryPath, [], {
      env: { ...process.env, DSH_HOME: path.join(testRoot, 'dsh-home') },
      encoding: 'utf8', timeout: 10000,
    })
    assert.equal(run.status, 0, run.stderr || run.stdout)
    assert.match(run.stdout, /swift browser access live policy harness passed/)
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})
