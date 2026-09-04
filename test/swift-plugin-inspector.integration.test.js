import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const sources = [
  path.join(testDirectory, '..', 'Sources', 'Plugins', 'DshPluginInspector.swift'),
  path.join(testDirectory, 'swift-plugin-inspector-harness.swift'),
]

test('Swift plugin inspector checks package, Bundle, host, patch, and failure contracts without mutation', () => {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-plugin-inspector-test-'))
  const binaryPath = path.join(testRoot, 'harness')
  const moduleCachePath = path.join(testRoot, 'module-cache')
  const tempRoot = path.join(testRoot, 'tmp')
  fs.mkdirSync(tempRoot, { recursive: true })
  const managedRuntimeCandidates = [process.env.DSH_PLUGIN_INSPECTOR_MANAGED_RUNTIME_ROOT].filter(Boolean)
  const managedRuntimeRoot = managedRuntimeCandidates.find((candidate) =>
    fs.existsSync(path.join(candidate, 'node_modules', 'js-yaml', 'package.json')))
  try {
    const compile = spawnSync('xcrun', [
      'swiftc',
      '-module-cache-path',
      moduleCachePath,
      ...sources,
      '-o',
      binaryPath,
    ], {
      encoding: 'utf8',
      timeout: 120000,
    })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    const run = spawnSync(binaryPath, [], {
      env: {
        ...process.env,
        TMPDIR: tempRoot,
        ...(managedRuntimeRoot
          ? {
              DSH_PLUGIN_INSPECTOR_TRUSTED_RUNTIME_ROOT: managedRuntimeRoot,
              DSH_PLUGIN_INSPECTOR_TRUSTED_NODE: process.execPath,
            }
          : {}),
      },
      encoding: 'utf8',
      timeout: 15000,
    })
    assert.equal(run.status, 0, run.stderr || run.stdout)
    assert.match(run.stdout, /swift plugin inspector harness passed/)
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})
