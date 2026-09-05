import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const scriptPath = path.join(repositoryDirectory, 'scripts', 'm2-acceptance.sh')

test('M2 acceptance entry point composes all isolated evidence groups', () => {
  const result = spawnSync('bash', [scriptPath, '--list'], {
    cwd: repositoryDirectory,
    encoding: 'utf8',
    timeout: 10000,
  })
  assert.equal(result.status, 0, result.stderr || result.stdout)
  for (const evidence of [
    'swift-plugin-operation.integration.test.js',
    'swift-plugin-product-chain.integration.test.js',
    'swift-plugin-ui-progress.test.js',
    'swift-plugin-failure-resolver.integration.test.js',
    'swift-recovery.integration.test.js',
    'swift-bridge-diagnostic.integration.test.js',
    'swift-diagnostic-export-product.integration.test.js',
    'swift-runtime-transaction.integration.test.js',
    'swift-web-profile-snapshot.integration.test.js',
  ]) {
    assert.match(result.stdout, new RegExp(evidence.replaceAll('.', '\\.') + '$', 'm'))
  }
  assert.match(result.stdout, /Real GUI\/WKWebView automation: NOT RUN by default/)
})
