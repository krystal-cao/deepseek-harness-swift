import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const handlerSource = fs.readFileSync(
  path.join(testDirectory, '..', 'Sources', 'Bridge', 'DshBridgeHandler.swift'),
  'utf8',
)
const shellSource = fs.readFileSync(
  path.join(testDirectory, '..', 'Sources', 'MainWindow', 'DshWebShell.swift'),
  'utf8',
)
const controllerSource = fs.readFileSync(
  path.join(testDirectory, '..', 'Sources', 'MainWindow', 'MainWindowController.swift'),
  'utf8',
)

test('WK bridge binds WebView, frame, origin and generation before dispatch', () => {
  assert.match(handlerSource, /message\.frameInfo\.isMainFrame/)
  assert.match(handlerSource, /message\.frameInfo\.securityOrigin\.protocol/)
  assert.match(handlerSource, /message\.frameInfo\.securityOrigin\.host/)
  assert.match(handlerSource, /message\.frameInfo\.securityOrigin\.port/)
  assert.match(handlerSource, /message\.webView\.map/)
  assert.match(handlerSource, /validator\.validate\(incoming, context: context\)/)
  assert.match(handlerSource, /updateValidationContext\(_ context: DshBridgeValidationContext\?\)/)
  assert.match(handlerSource, /dictionary\["launchID"\] = context\.launchID\.uuidString/)
  assert.match(handlerSource, /dictionary\["generationID"\] = context\.generationID\.uuidString/)
})

test('page bridge API sends requests only; native shell owns identity binding', () => {
  const scriptStart = handlerSource.indexOf('public static let scriptSource')
  const scriptEnd = handlerSource.indexOf('    """', scriptStart)
  assert.ok(scriptStart >= 0 && scriptEnd > scriptStart)
  const script = handlerSource.slice(scriptStart, scriptEnd)
  assert.doesNotMatch(script, /launchID|generationID/)
  assert.match(shellSource, /updateBridgeValidationContext\(/)
  assert.match(shellSource, /clearBridgeValidationContext\(\)/)
  assert.match(controllerSource, /webShell\?\.clearBridgeValidationContext\(\)/)
  assert.match(controllerSource, /updateBridgeValidationContext\(for: session\)/)
})

test('restart and safe-mode return invalidate stale bridge context at service boundaries', () => {
  const restartStart = controllerSource.indexOf(
    '    public func restartDshServiceDuringOperation('
  )
  const restartEnd = controllerSource.indexOf(
    '    private func inspectDependenciesBeforeMutation',
    restartStart,
  )
  assert.ok(restartStart >= 0 && restartEnd > restartStart)
  const restartBody = controllerSource.slice(restartStart, restartEnd)
  const clearIndex = restartBody.indexOf('webShell?.clearBridgeValidationContext()')
  const restartSessionNilIndex = restartBody.indexOf('serviceSession = nil')
  const launchIndex = restartBody.indexOf('launchContext = context')
  const prepareIndex = restartBody.indexOf('prepareForProfileMutation(context: context)')
  assert.ok(clearIndex >= 0 && clearIndex < restartSessionNilIndex)
  assert.ok(launchIndex > clearIndex && launchIndex < prepareIndex)

  const returnStart = controllerSource.indexOf('    private func returnFromSafeMode()')
  const returnEnd = controllerSource.indexOf(
    '    private func handleRecoveryRetry',
    returnStart,
  )
  assert.ok(returnStart >= 0 && returnEnd > returnStart)
  const returnBody = controllerSource.slice(returnStart, returnEnd)
  const stopIndex = returnBody.indexOf('DshService.shared.stopAndWait()')
  const firstClearIndex = returnBody.indexOf('webShell?.clearBridgeValidationContext()')
  const sessionNilIndex = returnBody.indexOf('self.serviceSession = nil')
  const secondClearIndex = returnBody.indexOf(
    'webShell?.clearBridgeValidationContext()',
    firstClearIndex + 1,
  )
  const contextGuardIndex = returnBody.indexOf('guard let context = self.makeLaunchContext()')
  assert.ok(firstClearIndex >= 0 && firstClearIndex < stopIndex)
  assert.ok(secondClearIndex > sessionNilIndex && secondClearIndex < contextGuardIndex)
})
