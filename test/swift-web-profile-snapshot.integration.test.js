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
  path.join(testDirectory, '..', 'Sources', 'Service', 'DshLaunchContext.swift'),
  path.join(testDirectory, '..', 'Sources', 'Service', 'DshSecretRedactor.swift'),
  path.join(testDirectory, '..', 'Sources', 'Versions', 'DshVersionManager.swift'),
  path.join(testDirectory, '..', 'Sources', 'Plugins', 'DshPluginManager.swift'),
  path.join(testDirectory, 'swift-web-profile-snapshot-harness.swift'),
]

test('Swift web Profile snapshot restores manifests and node_modules', () => {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-profile-snapshot-test-'))
  const binaryPath = path.join(testRoot, 'harness')
  const appSupportRoot = path.join(testRoot, 'application-support')
  const moduleCachePath = path.join(testRoot, 'module-cache')
  const tempRoot = path.join(testRoot, 'tmp')
  fs.mkdirSync(tempRoot, { recursive: true })
  try {
    const compile = spawnSync('xcrun', [
      'swiftc',
      '-D',
      'DSH_TESTING',
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

    const assetsRoot = path.join(testRoot, 'assets')
    const hostRoot = path.join(assetsRoot, 'dsh-desktop-host')
    const pnpmRoot = path.join(assetsRoot, 'bin')
    const nodeRoot = path.join(assetsRoot, 'node', 'bin')
    fs.mkdirSync(hostRoot, { recursive: true })
    fs.mkdirSync(pnpmRoot, { recursive: true })
    fs.mkdirSync(nodeRoot, { recursive: true })
    const requiredHostFiles = [
      'index.js', 'client.js', 'webserver.js', 'browser-url-route.js',
      'lan-url-route.js', 'lan-http-ingress.js', 'upstream-session-broker.js',
      'control.js', 'access-state.js', 'cordis.patch.yml',
    ]
    fs.writeFileSync(path.join(hostRoot, 'package.json'), JSON.stringify({
      name: 'dsh-desktop-host',
      version: '1.0.0',
      exports: { './webserver': './webserver.js' },
    }))
    for (const file of requiredHostFiles) fs.writeFileSync(path.join(hostRoot, file), `controlled-${file}\n`)
    fs.writeFileSync(path.join(nodeRoot, 'node'), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
    const fakePnpm = `#!${process.execPath}
import fs from 'node:fs'
import path from 'node:path'

const command = process.argv[2]
const args = process.argv.slice(3)
const profile = process.cwd()
const packageFile = path.join(profile, 'package.json')
const pkg = JSON.parse(fs.readFileSync(packageFile, 'utf8'))
pkg.dependencies ??= {}
const hostName = 'dsh-desktop-host'
const webServerName = '@deepseek-ai/dsh-host-webserver'
const hostDir = path.join(profile, 'node_modules', hostName)
const webServerDir = path.join(profile, 'node_modules', '@deepseek-ai', 'dsh-host-webserver')
if (process.env.DSH_TEST_PNPM_OUTPUT === '1') {
  const shapedToken = 'T'.repeat(43)
  process.stdout.write('stdout-' + 'x'.repeat(6000) + '?token=' + shapedToken + '\\n')
  process.stderr.write('Authorization: Bearer ' + shapedToken + '\\nCookie: session=' + shapedToken + '\\n' + 'y'.repeat(24000))
  process.exit(17)
}
if (command === 'add') {
  const hostSpec = args.find((value) => value.startsWith('file:'))
  const webServerSpec = args.find((value) => value.startsWith(webServerName + '@'))
  if (!hostSpec || !webServerSpec) process.exit(2)
  const version = webServerSpec.slice((webServerName + '@').length)
  pkg.dependencies[hostName] = hostSpec
  pkg.dependencies[webServerName] = version
  pkg.dsh ??= {}
  pkg.dsh.profile ??= {}
  pkg.dsh.profile.bundles ??= []
  if (!pkg.dsh.profile.bundles.includes(hostName)) pkg.dsh.profile.bundles.push(hostName)
  fs.mkdirSync(path.dirname(hostDir), { recursive: true })
  fs.cpSync(hostSpec.slice('file:'.length), hostDir, { recursive: true })
  fs.mkdirSync(path.dirname(webServerDir), { recursive: true })
  fs.mkdirSync(webServerDir, { recursive: true })
  fs.writeFileSync(path.join(webServerDir, 'package.json'), JSON.stringify({ name: webServerName, version }))
} else if (command === 'remove') {
  for (const name of args.filter((value) => !value.startsWith('-'))) {
    delete pkg.dependencies[name]
    if (name === hostName) fs.rmSync(hostDir, { recursive: true, force: true })
    if (name === webServerName) fs.rmSync(webServerDir, { recursive: true, force: true })
  }
}
fs.writeFileSync(packageFile, JSON.stringify(pkg))
`
    fs.writeFileSync(path.join(pnpmRoot, 'pnpm'), fakePnpm, { mode: 0o755 })

    const run = spawnSync(binaryPath, [], {
      env: {
        ...process.env,
        DSH_TEST_APP_SUPPORT: appSupportRoot,
        TMPDIR: tempRoot,
      },
      encoding: 'utf8',
      timeout: 10000,
    })
    assert.equal(run.status, 0, run.stderr || run.stdout)
    assert.match(run.stdout, /web profile snapshot and ownership integration harness passed/)
  } finally {
    try {
      fs.rmSync(testRoot, { recursive: true, force: true })
    } catch {
      // Keep the original assertion if a fixture path cannot be cleaned.
    }
  }
})
