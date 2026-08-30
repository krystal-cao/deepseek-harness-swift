import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const sources = [
  path.join(testDirectory, '..', 'Sources', 'State', 'DshState.swift'),
  path.join(testDirectory, '..', 'Sources', 'Versions', 'DshSemanticVersion.swift'),
  path.join(testDirectory, '..', 'Sources', 'Service', 'NodeRuntime.swift'),
  path.join(testDirectory, '..', 'Sources', 'Versions', 'DshVersionManager.swift'),
  path.join(testDirectory, '..', 'Sources', 'Plugins', 'DshPluginManager.swift'),
  path.join(testDirectory, 'swift-web-profile-snapshot-harness.swift'),
]

test('Swift web Profile snapshot restores manifests and node_modules', () => {
  const binaryPath = path.join(os.tmpdir(), 'dsh-profile-snapshot-' + process.pid)
  try {
    const compile = spawnSync('xcrun', ['swiftc', ...sources, '-o', binaryPath], {
      encoding: 'utf8',
      timeout: 120000,
    })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    const run = spawnSync(binaryPath, [], {
      encoding: 'utf8',
      timeout: 10000,
    })
    assert.equal(run.status, 0, run.stderr || run.stdout)
    assert.match(run.stdout, /web profile snapshot integration harness passed/)
  } finally {
    try {
      fs.unlinkSync(binaryPath)
    } catch {
      // The compiler may not have produced a binary after a failed build.
    }
  }
})
