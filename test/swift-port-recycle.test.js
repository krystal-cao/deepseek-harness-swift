import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const SERVICE_SOURCE = fs.readFileSync(
  new URL('../Sources/Service/DshService.swift', import.meta.url),
  'utf8',
)

test('Swift DSH service records process ownership and can kill its process group', () => {
  assert.match(SERVICE_SOURCE, /makeProcessGroupLeader\(proc\)/)
  assert.match(SERVICE_SOURCE, /setpgid\(pid, pid\)/)
  assert.match(SERVICE_SOURCE, /ManagedDshProcess/)
  assert.match(SERVICE_SOURCE, /hasProcessGroup/)
  assert.match(SERVICE_SOURCE, /processGroupID/)
  assert.match(SERVICE_SOURCE, /kill\(-pid, signal\)/)
})

test('Swift DSH service no longer relies on a delayed SIGKILL that never fires on quit', () => {
  // The old code scheduled SIGKILL on a background queue; quitting the app
  // stopped the runloop before it could run, orphaning the DSH web server and
  // leaving the port occupied on the next launch.
  assert.doesNotMatch(SERVICE_SOURCE, /asyncAfter.*SIGKILL/)
  assert.match(SERVICE_SOURCE, /signalManagedProcess\(managed, SIGTERM\)/)
  assert.match(SERVICE_SOURCE, /signalManagedProcess\(managed, SIGKILL\)/)
})

test('Swift DSH service reclaims a stale server bound to its port on startup', () => {
  assert.match(SERVICE_SOURCE, /recycleStaleDshServerIfNeeded\(\)/)
  assert.match(SERVICE_SOURCE, /dsh-service-process\.json/)
  assert.match(SERVICE_SOURCE, /listeningPids\(on: record\.port\)/)
  assert.doesNotMatch(SERVICE_SOURCE, /record\.port == actualPort/)
  assert.match(SERVICE_SOURCE, /record\.nodePath/)
  assert.match(SERVICE_SOURCE, /processExecutablePath/)
  assert.match(SERVICE_SOURCE, /processStartTime/)
  assert.match(SERVICE_SOURCE, /proc_pidpath/)
  assert.match(SERVICE_SOURCE, /\/usr\/sbin\/lsof/)
})

test('Swift DSH service avoids direct PID fallback after the process exits', () => {
  assert.match(SERVICE_SOURCE, /if managed\.hasProcessGroup \{[\s\S]*kill\(-pid, signal\)/)
  assert.match(SERVICE_SOURCE, /else if managed\.process\.isRunning \{\n\s+_ = kill\(pid, signal\)/)
  assert.match(SERVICE_SOURCE, /direct kill at this point could hit a recycled PID/)
})
