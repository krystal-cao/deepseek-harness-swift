import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const stateSource = path.join(testDirectory, '..', 'Sources', 'State', 'DshState.swift')
const harnessSource = path.join(testDirectory, 'swift-runtime-recovery-harness.swift')

test('Swift runtime recovery executes crash-phase integration scenarios', () => {
  const binaryPath = path.join(os.tmpdir(), 'dsh-runtime-recovery-' + process.pid)
  try {
    const compile = spawnSync('xcrun', ['swiftc', stateSource, harnessSource, '-o', binaryPath], {
      encoding: 'utf8',
      timeout: 120000,
    })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    const run = spawnSync(binaryPath, [], {
      encoding: 'utf8',
      timeout: 10000,
    })
    assert.equal(run.status, 0, run.stderr || run.stdout)
    assert.match(run.stdout, /runtime recovery integration harness passed/)
  } finally {
    try {
      fs.unlinkSync(binaryPath)
    } catch {
      // The compiler may not have produced a binary after a failed build.
    }
  }
})
