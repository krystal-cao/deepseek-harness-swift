import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import http from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const handlerSource = path.join(repositoryDirectory, 'Sources', 'Bridge', 'DshBridgeHandler.swift')
const validatorSource = path.join(repositoryDirectory, 'Sources', 'Bridge', 'DshBridgeMessageValidator.swift')
const harnessSource = path.join(testDirectory, 'swift-real-bridge-acceptance-harness.swift')

function runProcess(binaryPath, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, args, options)
    let stdout = ''
    let stderr = ''
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.once('error', reject)
    child.once('close', (code, signal) => resolve({ code, signal, stdout, stderr }))
  })
}

function startFixtureServer() {
  const server = http.createServer((request, response) => {
    const requestURL = new URL(request.url, 'http://127.0.0.1')
    if (requestURL.pathname !== '/bridge' && requestURL.pathname !== '/frame') {
      response.writeHead(404)
      response.end('not found')
      return
    }
    const html = requestURL.pathname === '/frame'
      ? '<!doctype html><html><body><main>B01 iframe fixture</main><script>window.dshDesktop.ready();</script></body></html>'
      : '<!doctype html><html><body><main>B01 bridge fixture</main><iframe src="/frame"></iframe></body></html>'
    response.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'Content-Length': Buffer.byteLength(html),
    })
    response.end(html)
  })
  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', reject)
      const address = server.address()
      assert.equal(typeof address, 'object')
      resolve({ server, port: address.port })
    })
  })
}

test('real WKWebView bridge accepts only the current native source and generation', {
  skip: process.env.DSH_B01_WKWEBVIEW !== '1'
    ? 'set DSH_B01_WKWEBVIEW=1 to run the real B01 WebKit harness'
    : false,
}, async () => {
  assert.equal(process.platform, 'darwin', 'real B01 harness requires macOS WebKit')
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-b01-real-bridge-'))
  const fixture = await startFixtureServer()
  const binaryPath = path.join(root, 'real-bridge-harness')
  const moduleCachePath = path.join(root, 'module-cache')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc',
      '-parse-as-library',
      '-module-cache-path', moduleCachePath,
      validatorSource,
      handlerSource,
      harnessSource,
      '-framework', 'AppKit',
      '-framework', 'WebKit',
      '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    const run = await runProcess(binaryPath, [`http://127.0.0.1:${fixture.port}/bridge`], {
      env: { ...process.env, TMPDIR: root },
      encoding: 'utf8',
      timeout: 30000,
    })
    assert.equal(run.code, 0, `${run.stderr}\n${run.stdout}`)
    assert.match(run.stdout, /real B01 ready callback count=1/)
    assert.match(run.stdout, /real B01 rejected iframe=1 old-generation=1 wrong-webview=1/)
    assert.match(run.stdout, /swift real bridge acceptance harness passed/)
  } finally {
    await new Promise((resolve) => fixture.server.close(resolve))
    fs.rmSync(root, { recursive: true, force: true })
  }
})
