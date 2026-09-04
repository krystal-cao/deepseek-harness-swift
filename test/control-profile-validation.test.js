import assert from 'node:assert/strict'
import test from 'node:test'
import { validateBootstrap } from '../assets/dsh-desktop-host/control.js'

const baseMessage = {
  v: 1,
  type: 'bootstrap',
  entryPath: '/tmp/dsh-entry.js',
  host: '127.0.0.1',
  port: 3080,
  generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  rendererToken: 'a'.repeat(43),
  ordinaryBrowserEnabled: false,
  networkExposure: 'loopback',
}

test('Swift and desktop host accept the same bounded Profile labels', () => {
  for (const profile of ['desktop', 'web', 'dsh-recovery-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa']) {
    assert.equal(validateBootstrap({ ...baseMessage, profile }).profile, profile)
  }
  for (const profile of [
    'other', '../desktop', '/tmp/desktop', '.', '..', '.hidden', '-desktop',
    'dsh-recovery-aaaaaaaa-aaaa-0aaa-8aaa-aaaaaaaaaaaa',
    'dsh-recovery-aaaaaaaa-aaaa-4aaa-7aaa-aaaaaaaaaaaa',
    '桌面',
  ]) {
    assert.throws(() => validateBootstrap({ ...baseMessage, profile }), /invalid bootstrap profile/)
  }
})
