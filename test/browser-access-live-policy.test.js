import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const ACCESS_SOURCE = read('../Sources/Service/DshAccessController.swift')
const SERVICE_SOURCE = read('../Sources/Service/DshService.swift')
const WINDOW_SOURCE = read('../Sources/MainWindow/MainWindowController.swift')
const SETTINGS_SOURCE = read('../Sources/SettingsUI/SettingsViewModel.swift')

test('opening immediately after enabling uses the ACKed live generation policy', () => {
  // Reproduces the original failure shape: the startup context remains
  // loopback-only while the settings mutation enables the running generation.
  // The browser guard must follow the latter only after DshProcessIO confirms
  // the matching policy revision.
  assert.match(ACCESS_SOURCE, /commitPolicy\(/)
  assert.match(SERVICE_SOURCE, /waitForPolicyApplied\([\s\S]*commitPolicy\(/)
  assert.match(SERVICE_SOURCE, /currentAccessPolicy\(for generationID: UUID\)/)

  const browserFetch = WINDOW_SOURCE.slice(
    WINDOW_SOURCE.indexOf('public func fetchAuthenticatedBrowserURL()'),
    WINDOW_SOURCE.indexOf('    public enum LANURLError', WINDOW_SOURCE.indexOf('public func fetchAuthenticatedBrowserURL()'))
  )
  assert.match(browserFetch, /currentAccessPolicy\(for: session\.access\.id\)/)
  assert.match(browserFetch, /livePolicy\.browserAccessEnabled/)
  assert.doesNotMatch(browserFetch, /session\.context\.effectiveAccessPolicy\.browserAccessEnabled/)

  const runtimeHealth = WINDOW_SOURCE.slice(
    WINDOW_SOURCE.indexOf('private func verifyRuntimeHealth('),
    WINDOW_SOURCE.indexOf('    private func verifyWebKitConnection', WINDOW_SOURCE.indexOf('private func verifyRuntimeHealth('))
  )
  assert.match(runtimeHealth, /currentAccessPolicy\(for: session\.access\.id\)/)
  assert.match(runtimeHealth, /accessPolicy: liveAccessPolicy/)
  assert.match(runtimeHealth, /liveAccessPolicy\.networkExposure == \.lan/)
  assert.match(runtimeHealth, /RuntimeHealthError\.liveAccessPolicyUnavailable/)
  assert.doesNotMatch(runtimeHealth, /session\.context\.effectiveAccessPolicy\.(browserAccessEnabled|networkExposure)/)

  const browserBoundary = WINDOW_SOURCE.slice(
    WINDOW_SOURCE.indexOf('private func verifyBrowserAccessBoundary('),
    WINDOW_SOURCE.indexOf('    private func verifyLANAccessBoundary', WINDOW_SOURCE.indexOf('private func verifyBrowserAccessBoundary('))
  )
  assert.match(browserBoundary, /accessPolicy: DshEffectiveAccessPolicy/)
  assert.match(browserBoundary, /let browserEnabled = accessPolicy\.browserAccessEnabled/)

  const lanBoundary = WINDOW_SOURCE.slice(
    WINDOW_SOURCE.indexOf('private func verifyLANAccessBoundary('),
    WINDOW_SOURCE.indexOf('    private func runtimeHealthRequest', WINDOW_SOURCE.indexOf('private func verifyLANAccessBoundary('))
  )
  assert.match(lanBoundary, /accessPolicy\.networkExposure == \.lan/)
  assert.match(lanBoundary, /accessPolicy\.browserAccessEnabled/)

  // The UI still persists the setting only after the live service call, and
  // a failed ACK rolls the durable and published state back to false.
  assert.match(SETTINGS_SOURCE, /DshStateManager\.shared\.update \{ \$0\.browserAccessEnabled = true \}/)
  assert.match(SETTINGS_SOURCE, /try await DshService\.shared\.setBrowserAccessEnabled\(true\)/)
  assert.match(SETTINGS_SOURCE, /DshStateManager\.shared\.update \{ \$0\.browserAccessEnabled = previous \}/)
})
