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
  path.join(testDirectory, '..', 'Sources', 'Service', 'DshLaunchContext.swift'),
  path.join(testDirectory, 'swift-launch-context-harness.swift'),
]

test('Swift launch context freezes home, targets, policies, and transaction identity', () => {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-launch-context-test-'))
  const binaryPath = path.join(testRoot, 'harness')
  const moduleCachePath = path.join(testRoot, 'module-cache')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc', '-D', 'DSH_TESTING', '-module-cache-path', moduleCachePath,
      ...sources, '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    const cases = [
      [path.join(testRoot, 'dsh-home'), path.join(testRoot, 'dsh-home')],
      ['', path.join(process.env.HOME, '.dsh')],
      ['~', process.env.HOME],
      ['relative-dsh-home', path.resolve('relative-dsh-home')],
    ]
    for (const [value, expectedHome] of cases) {
      const run = spawnSync(binaryPath, [], {
        env: { ...process.env, DSH_HOME: value },
        encoding: 'utf8', timeout: 10000,
      })
      assert.equal(run.status, 0, `${value}: ${run.stderr || run.stdout}`)
      assert.match(run.stdout, new RegExp(`effective-home=${expectedHome.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')}`))
      assert.match(run.stdout, /swift launch context harness passed/)
    }
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})
