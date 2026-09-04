import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const source = fs.readFileSync(new URL('../Sources/Plugins/DshPluginManager.swift', import.meta.url), 'utf8')

test('plugin update inspection is strictly read-only', () => {
  const start = source.indexOf('public func checkOutdatedPlugins()')
  const end = source.indexOf('    /// Add a plugin by name or npm specifier.', start)
  assert.ok(start >= 0 && end > start, 'checkOutdatedPlugins implementation must remain discoverable')
  const checkSource = source.slice(start, end)

  assert.match(checkSource, /"outdated"/)
  assert.doesNotMatch(checkSource, /repairDesktopHostDependency/)
  assert.doesNotMatch(checkSource, /ensureManagedProfileWorkspaceConfiguration/)
  assert.doesNotMatch(checkSource, /createDirectory|write\(|removeItem|updateProfileBundle/)
})

test('desktop bridge cleanup requires persistent ownership proof', () => {
  assert.match(source, /desktopHostOwnershipMarkerName/)
  assert.match(source, /writeDesktopHostOwnershipProof\(/)
  assert.match(source, /verifyDesktopHostOwnershipProof\(/)
  assert.match(source, /sourceFingerprint/)
  assert.match(source, /installedFingerprint/)
  assert.match(source, /webServerManifestFingerprint/)
  assert.match(source, /try verifyDesktopHostOwnershipProof\([\s\S]*profileDir: profileDir/)
  assert.match(source, /清理 web Profile 桥接依赖/)
  assert.match(source, /安装桌面桥接依赖/)
  assert.match(source, /adoptDesktopHostOwnershipProof\(/)
  assert.match(source, /staleAppBridgeRejectionReason\(/)
})

test('launch integration can classify fresh versus existing Profiles before bootstrap', () => {
  assert.match(source, /enum DshProfileBootstrapReadiness/)
  assert.match(source, /case freshEmpty/)
  assert.match(source, /case existingUninitialized/)
  assert.ok(source.includes('public func bootstrapReadiness(at profileDir: URL)'))
  assert.match(source, /enum DshPluginStartupGateDecision/)
  assert.match(source, /allowFreshProfileBootstrap/)
  assert.ok(source.includes('inspectionHasUnknowns: Bool = false'))
  assert.ok(source.includes('profileReadiness == .freshEmpty'))
  assert.ok(source.includes('return .blockProfileMutation'))
})

test('process diagnostics redact secrets and apply byte and character limits', () => {
  assert.match(source, /DshSecretRedactor\(\)\.redact\(text\)/)
  assert.match(source, /processOutputByteLimit = 32 \* 1024/)
  assert.match(source, /processOutputCharacterLimit = 8 \* 1024/)
  assert.match(source, /data\.prefix\(Self\.processOutputByteLimit\)/)
  assert.match(source, /capProcessOutputCharacters\(detail\)/)
  assert.match(source, /capProcessOutputBytes\(detail\)/)
})
