import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const resolverPath = path.join(
  repositoryDirectory, 'Sources', 'Plugins', 'DshPluginFailureResolver.swift'
)
const sources = [
  path.join(repositoryDirectory, 'Sources', 'Diagnostics', 'DshDiagnostic.swift'),
  path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginInspector.swift'),
  resolverPath,
  path.join(testDirectory, 'swift-plugin-failure-resolver-harness.swift'),
]

test('P03 failure resolver stays conservative and emits preview-only plans', () => {
  const resolver = fs.readFileSync(resolverPath, 'utf8')
  assert.match(resolver, /case located = "已定位"/)
  assert.match(resolver, /case suspected = "疑似相关"/)
  assert.match(resolver, /case unknown = "无法确定"/)
  assert.match(resolver, /DshDiagnosticRecord/)
  assert.match(resolver, /DshPluginInspectionResult/)
  assert.match(resolver, /modulePaths/)
  assert.match(resolver, /DshPluginDependencyRelation/)
  assert.match(resolver, /patchInspectionUnavailable/)
  assert.match(resolver, /受管理核心组件禁止移除/)
  assert.match(resolver, /@deepseek-ai\/dsh-base/)
  assert.match(resolver, /@deepseek-ai\/dsh-web-app/)
  assert.match(resolver, /isInstalledProfileRoot/)
  assert.match(resolver, /public var isExecutable: Bool \{ false \}/)
  assert.doesNotMatch(resolver, /\.removePlugin\(/)
  assert.doesNotMatch(resolver, /Process\(/)

  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-plugin-failure-resolver-'))
  const moduleCachePath = path.join(testRoot, 'module-cache')
  const binaryPath = path.join(testRoot, 'harness')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc', '-module-cache-path', moduleCachePath, ...sources, '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)
    const run = spawnSync(binaryPath, [], {
      encoding: 'utf8',
      timeout: 15000,
    })
    assert.equal(run.status, 0, `${run.stdout}\n${run.stderr}`)
    assert.match(run.stdout, /swift plugin failure resolver harness passed/)
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})
