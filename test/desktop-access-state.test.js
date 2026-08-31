import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import http from 'node:http'
import net from 'node:net'
import { randomBytes } from 'node:crypto'
import test from 'node:test'

import {
  CLASSIFICATIONS,
  LAN_COOKIE_NAME,
  browserCredentialForLan,
  createAccessState,
  decideRequest,
  hasValidBrowserCredential,
  hasValidLanCredential,
  hasReservedDesktopParameter,
  hasValidRendererCookie,
  NETWORK_EXPOSURES,
  requestPassesLoopbackFence,
} from '../assets/dsh-desktop-host/access-state.js'
import { createBrowserURLRoute } from '../assets/dsh-desktop-host/browser-url-route.js'
import { createBrowserHandoffRoute } from '../assets/dsh-desktop-host/browser-url-route.js'
import {
  backendHeaders,
  createLanHTTPIngress,
  getLanIPv4Addresses,
  responseHeaders,
  sanitizedCookies,
} from '../assets/dsh-desktop-host/lan-http-ingress.js'
import { createLanURLRoute } from '../assets/dsh-desktop-host/lan-url-route.js'
import { createUpstreamAuthFixture, LAUNCH_TOKEN } from './fixtures/upstream-auth/server.mjs'

function token() {
  return randomBytes(32).toString('base64url')
}

function generation() {
  return '11111111-1111-4111-8111-111111111111'
}

function managedState({ ordinaryBrowserEnabled = false } = {}) {
  const state = createAccessState({ managedLaunch: true, port: 3187 })
  state.initializeGeneration({
    generation: generation(),
    rendererToken: token(),
    ordinaryBrowserEnabled,
  })
  return state
}

function request({ cookie, host = '127.0.0.1:3187', origin, url = '/', method = 'GET' } = {}) {
  return {
    method,
    url,
    headers: {
      host,
      ...(cookie === undefined ? {} : { cookie }),
      ...(origin === undefined ? {} : { origin }),
    },
  }
}

function httpRequest({ port, path, cookie, method = 'GET', host = `127.0.0.1:${port}` }) {
  return new Promise((resolve, reject) => {
    const requestObject = http.request({
      host: '127.0.0.1',
      port,
      path,
      method,
      headers: { host, ...(cookie === undefined ? {} : { cookie }) },
    }, (response) => {
      const chunks = []
      response.on('data', (chunk) => chunks.push(chunk))
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }))
    })
    requestObject.on('error', reject)
    requestObject.end()
  })
}

test('managed launches fail closed until the matching renderer cookie is present', () => {
  const state = createAccessState({ managedLaunch: true, port: 3187 })
  const beforeHandshake = request()

  assert.equal(decideRequest(beforeHandshake, state), CLASSIFICATIONS.denied)
  assert.equal(requestPassesLoopbackFence(beforeHandshake, state), true)

  state.initializeGeneration({
    generation: generation(),
    rendererToken: token(),
    ordinaryBrowserEnabled: false,
  })

  assert.equal(decideRequest(request(), state), CLASSIFICATIONS.denied)
  assert.equal(
    decideRequest(request({ cookie: 'dsh_swift_renderer=' + state.rendererToken }), state),
    CLASSIFICATIONS.renderer,
  )
  assert.equal(
    decideRequest(
      request({ cookie: 'dsh_swift_renderer=' + state.rendererToken + '; dsh_swift_renderer=other' }),
      state,
    ),
    CLASSIFICATIONS.denied,
  )
})

test('renderer credentials are exact, canonical 32-byte base64url values', () => {
  const state = managedState()
  const cookie = 'dsh_swift_renderer=' + state.rendererToken

  assert.equal(hasValidRendererCookie({ cookie }, state.rendererToken), true)
  assert.equal(hasValidRendererCookie({ cookie: cookie + '=' }, state.rendererToken), false)
  assert.equal(hasValidRendererCookie({ cookie: 'dsh_swift_renderer=short' }, state.rendererToken), false)
  assert.equal(hasValidRendererCookie({ cookie: 'dsh_swift_renderer=' + token() }, token()), false)
})

test('ordinary browser access is separately gated and reserved parameters stay denied', () => {
  const state = managedState({ ordinaryBrowserEnabled: true })

  assert.equal(decideRequest(request(), state), CLASSIFICATIONS.denied)
  const authenticatedURL = new URL(state.authenticatedUrl())
  assert.equal(authenticatedURL.hostname, '127.0.0.1')
  assert.equal(authenticatedURL.port, '3187')
  assert.equal(authenticatedURL.searchParams.has('dsh-auth'), true)
  assert.equal(
    hasValidBrowserCredential({ url: authenticatedURL.toString(), headers: {} }, state),
    true,
  )
  assert.equal(
    decideRequest(request({ url: authenticatedURL.toString() }), state),
    CLASSIFICATIONS.browser,
  )
  assert.equal(
    decideRequest(request({ url: '/?dsh-desktop-debug=1' }), state),
    CLASSIFICATIONS.denied,
  )
  assert.equal(hasReservedDesktopParameter('/?dsh-desktop-debug=1'), true)
  assert.equal(hasReservedDesktopParameter('/?dsh-swift-internal=1'), true)
  assert.equal(hasReservedDesktopParameter('/?ordinary=1'), false)

  assert.equal(requestPassesLoopbackFence(request(), state), true)
  assert.equal(requestPassesLoopbackFence(request({ host: 'localhost:3187' }), state), false)
  assert.equal(requestPassesLoopbackFence(request({ origin: 'http://localhost:3187' }), state), false)
  assert.equal(requestPassesLoopbackFence(request({ origin: 'http://127.0.0.1:3187' }), state), true)
})

test('the private browser URL route issues a one-time handoff and installs B on the first browser request', async () => {
  const state = managedState({ ordinaryBrowserEnabled: true })
  const route = createBrowserURLRoute({}, state)
  const response = {
    status: undefined,
    headers: {},
    body: '',
    writeHead(status, headers) {
      this.status = status
      Object.assign(this.headers, headers)
    },
    setHeader(name, value) {
      this.headers[name.toLowerCase()] = value
    },
    end(body = '') {
      this.body = body
    },
  }

  await route.handler(
    request({
      cookie: 'dsh_swift_renderer=' + state.rendererToken,
      url: 'http://127.0.0.1:3187/__dsh_swift/browser-url',
      method: 'POST',
    }),
    response,
  )

  assert.equal(response.status, 200)
  const payload = JSON.parse(response.body)
  const url = new URL(payload.url)
  assert.equal(url.hostname, '127.0.0.1')
  assert.equal(url.port, '3187')
  assert.equal(url.pathname, '/__dsh_swift/browser-handoff')
  assert.equal(hasValidBrowserCredential({ url: payload.url, headers: {} }, state), true)
  assert.equal(response.headers['set-cookie'], undefined)

  const handoffResponse = { ...response, status: undefined, headers: {}, body: '' }
  await createBrowserHandoffRoute(state).handler(
    request({ url: payload.url, method: 'GET' }),
    handoffResponse,
  )
  assert.equal(handoffResponse.status, 303)
  assert.equal(handoffResponse.headers.location, 'http://127.0.0.1:3187/')
  assert.match(handoffResponse.headers['set-cookie'], /^dsh_browser_auth=.*Max-Age=600/)

  const replayResponse = { ...response, status: undefined, headers: {}, body: '' }
  await createBrowserHandoffRoute(state).handler(
    request({ url: payload.url, method: 'GET' }),
    replayResponse,
  )
  assert.equal(replayResponse.status, 403)

  const denied = { ...response, status: undefined, headers: {}, body: '' }
  await route.handler(
    request({ url: 'http://127.0.0.1:3187/__dsh_swift/browser-url', method: 'POST' }),
    denied,
  )
  assert.equal(denied.status, 403)
})

test('browser URL providers receive the loopback origin and provider failures do not downgrade alpha auth', async () => {
  const state = managedState({ ordinaryBrowserEnabled: true })
  const calls = []
  const route = createBrowserURLRoute({
    inject(deps, callback) {
      assert.deepEqual(deps, ['connection'])
      callback({
        connection: {
          authenticatedUrl(baseURL) {
            calls.push(baseURL)
            return state.authenticatedUrl()
          },
        },
      })
      },
  }, state)
  const response = {
    status: undefined,
    headers: {},
    body: '',
    writeHead(status, headers) {
      this.status = status
      Object.assign(this.headers, headers)
    },
    setHeader(name, value) {
      this.headers[name.toLowerCase()] = value
    },
    end(body = '') {
      this.body = body
    },
  }

  await route.handler(
    request({
      cookie: 'dsh_swift_renderer=' + state.rendererToken,
      url: 'http://127.0.0.1:3187/__dsh_swift/browser-url',
      method: 'POST',
    }),
    response,
  )
  assert.deepEqual(calls, ['http://127.0.0.1:3187'])
  assert.equal(response.status, 200)
  assert.equal(new URL(JSON.parse(response.body).url).pathname, '/__dsh_swift/browser-handoff')

  const failedState = managedState({ ordinaryBrowserEnabled: true })
  const failedRoute = createBrowserURLRoute({
    inject(deps, callback) {
      assert.deepEqual(deps, ['connection'])
      callback({
        connection: {
          authenticatedUrl() {
            throw new Error('unsupported provider')
          },
        },
      })
    },
  }, failedState)
  const failedResponse = { ...response, status: undefined, headers: {}, body: '' }
  await failedRoute.handler(
    request({
      cookie: 'dsh_swift_renderer=' + failedState.rendererToken,
      url: 'http://127.0.0.1:3187/__dsh_swift/browser-url',
      method: 'POST',
    }),
    failedResponse,
  )
  assert.equal(failedResponse.status, 503)
  assert.equal(failedState.browserTokens.size, 0)
})

test('Browser handoff completes the alpha.2 token exchange without exposing the upstream token in the returned URL', async (t) => {
  const fixture = await createUpstreamAuthFixture({ mode: 'alpha' })
  t.after(() => fixture.close())
  const state = managedState({ ordinaryBrowserEnabled: true })
  state.port = fixture.port
  const route = createBrowserURLRoute({
    inject(_deps, callback) {
      callback({ connection: { authenticatedUrl: () => fixture.launchURL } })
    },
  }, state)
  const response = {
    status: undefined,
    headers: {},
    body: '',
    writeHead(status, headers) {
      this.status = status
      Object.assign(this.headers, headers)
    },
    end(body = '') {
      this.body = body
    },
  }

  await route.handler(request({
    host: `127.0.0.1:${fixture.port}`,
    cookie: 'dsh_swift_renderer=' + state.rendererToken,
    url: `http://127.0.0.1:${fixture.port}/__dsh_swift/browser-url`,
    method: 'POST',
  }), response)
  assert.equal(response.status, 200)
  const handoffURL = new URL(JSON.parse(response.body).url)
  assert.equal(handoffURL.pathname, '/__dsh_swift/browser-handoff')
  assert.equal(handoffURL.searchParams.has('token'), false)

  const handoffResponse = { ...response, status: undefined, headers: {}, body: '' }
  await createBrowserHandoffRoute(state).handler(request({
    host: `127.0.0.1:${fixture.port}`,
    url: handoffURL.toString(),
  }), handoffResponse)
  const browserCookie = handoffResponse.headers['set-cookie'].split(';', 1)[0]
  assert.equal(handoffResponse.status, 303)
  assert.equal(handoffResponse.headers.location, fixture.launchURL)

  const exchange = await httpRequest({ port: fixture.port, path: `/?token=${encodeURIComponent(LAUNCH_TOKEN)}`, cookie: browserCookie })
  assert.equal(exchange.status, 303)
  const upstreamCookie = exchange.headers['set-cookie'][0].split(';', 1)[0]
  const page = await httpRequest({ port: fixture.port, path: '/', cookie: `${browserCookie}; ${upstreamCookie}` })
  assert.equal(page.status, 200)
  assert.match(page.body, /DSH fixture/)
})

test('generation state accepts only the next policy revision and can close ordinary sockets', async () => {
  const state = managedState({ ordinaryBrowserEnabled: true })
  const socket = new EventEmitter()
  socket.destroyed = false
  socket.destroy = () => {
    socket.destroyed = true
    socket.emit('close')
  }
  state.trackOrdinarySocket(socket)

  const changes = []
  state.observePolicy((change) => {
    changes.push(change)
    if (!change.ordinaryBrowserEnabled) state.closeOrdinarySockets()
  })

  await assert.rejects(
    state.applyPolicy({
      generation: state.generation,
      revision: 2,
      ordinaryBrowserEnabled: false,
    }),
    /revision gap/,
  )
  assert.deepEqual(
    await state.applyPolicy({
      generation: state.generation,
      revision: 1,
      ordinaryBrowserEnabled: false,
    }),
    { revision: 1, ordinaryBrowserEnabled: false, networkExposure: NETWORK_EXPOSURES.loopback, changed: true },
  )
  assert.equal(socket.destroyed, true)
  assert.deepEqual(
    await state.applyPolicy({
      generation: state.generation,
      revision: 1,
      ordinaryBrowserEnabled: true,
    }),
    { revision: 1, ordinaryBrowserEnabled: false, networkExposure: NETWORK_EXPOSURES.loopback, changed: false },
  )
  assert.equal(changes.length, 1)
})

test('controlled shutdown revokes credentials and stops the LAN ingress', async () => {
  const state = managedState({ ordinaryBrowserEnabled: true })
  state.networkExposure = NETWORK_EXPOSURES.lan
  const browserToken = token()
  const lanToken = token()
  state.browserTokens.set(browserToken, Date.now() + 60_000)
  assert.ok(state.issueBrowserHandoff('http://127.0.0.1:3187/?token=secret'))
  state.lanTokens.set(lanToken, Date.now() + 60_000)
  state.lanBrowserTokens.set(lanToken, { browserToken, expiresAt: Date.now() + 60_000 })
  let stopped = false
  state.lanIngress = { stop: async () => { stopped = true } }

  await state.shutdownControlledAccess()

  assert.equal(stopped, true)
  assert.equal(state.ordinaryBrowserEnabled, false)
  assert.equal(state.networkExposure, NETWORK_EXPOSURES.loopback)
  assert.equal(state.browserTokens.size, 0)
  assert.equal(state.browserHandoffs.size, 0)
  assert.equal(state.lanTokens.size, 0)
  assert.equal(state.lanBrowserTokens.size, 0)
  assert.equal(state.lanIngress, undefined)
})

test('LAN proxy credentials are broker-owned and auth-bearing response metadata is removed', () => {
  const state = managedState({ ordinaryBrowserEnabled: true })
  const browserToken = token()
  state.browserTokens.set(browserToken, Date.now() + 60_000)
  const request = {
    headers: {
      cookie: `dsh_swift_renderer=${state.rendererToken}; dsh_lan_auth=lan; dsh-auth-forged=upstream; theme=dark`,
      host: '192.168.1.8:4199',
      origin: 'http://192.168.1.8:4199',
    },
    url: '/?dsh-auth=lan&token=secret&keep=yes',
  }
  assert.equal(sanitizedCookies(request, browserToken, 'dsh-auth-real=broker-value'), `theme=dark; dsh_browser_auth=${browserToken}; dsh-auth-real=broker-value`)
  const headers = backendHeaders(request, browserToken, 'dsh-auth-real=broker-value', 3187)
  assert.equal(headers.host, '127.0.0.1:3187')
  assert.equal(headers.origin, undefined)
  assert.equal(headers.authorization, undefined)
  assert.equal(headers.cookie.includes('dsh-auth-forged'), false)

  const output = responseHeaders({
    location: '/?token=secret',
    'set-cookie': [
      'dsh-auth-real=upstream; Path=/',
      'dsh_browser_auth=browser; Path=/',
      'theme=dark; Path=/',
    ],
  }, { ...request, backendPort: 3187 })
  assert.equal(output.location, undefined)
  assert.deepEqual(output['set-cookie'], ['theme=dark; Path=/'])
})

test('LAN URL issuance is Renderer-only and requires the separate LAN policy', async () => {
  const state = managedState({ ordinaryBrowserEnabled: true })
  state.networkExposure = NETWORK_EXPOSURES.lan
  state.lanIngress = {
    port: () => 4199,
    addresses: () => ['192.168.1.8'],
  }
  const route = createLanURLRoute(state)
  const response = {
    status: undefined,
    headers: {},
    body: '',
    writeHead(status, headers) {
      this.status = status
      Object.assign(this.headers, headers)
    },
    end(body = '') {
      this.body = body
    },
  }

  await route.handler(request({
    cookie: 'dsh_swift_renderer=' + state.rendererToken,
    url: 'http://127.0.0.1:3187/__dsh_swift/lan-url',
    method: 'POST',
  }), response)

  assert.equal(response.status, 200)
  const payload = JSON.parse(response.body)
  assert.match(payload.url, /^http:\/\/192\.168\.1\.8:4199\/\?dsh-auth=/)
  const credential = new URL(payload.url).searchParams.get('dsh-auth')
  assert.equal(hasValidLanCredential({ url: payload.url, headers: {} }, state), true)
  assert.equal(state.lanTokens.has(credential), true)

  const denied = { ...response, status: undefined, headers: {}, body: '' }
  await route.handler(request({ url: 'http://127.0.0.1:3187/__dsh_swift/lan-url', method: 'POST' }), denied)
  assert.equal(denied.status, 403)
})

test('LAN HTTP ingress proxies only an authenticated public request and strips Renderer identity', async () => {
  const backend = http.createServer((request, response) => {
    response.setHeader('content-type', 'text/plain')
    response.end(JSON.stringify({ host: request.headers.host, cookie: request.headers.cookie, url: request.url }))
  })
  await new Promise((resolve) => backend.listen(0, '127.0.0.1', resolve))
  const backendPort = backend.address().port
  const state = managedState({ ordinaryBrowserEnabled: true })
  state.port = backendPort
  state.networkExposure = NETWORK_EXPOSURES.lan
  const credential = token()
  state.lanTokens.set(credential, Date.now() + 60_000)
  const ingress = createLanHTTPIngress({
    backendPort,
    state,
    listenHost: '127.0.0.1',
    addressProvider: () => ['127.0.0.1'],
  })

  try {
    await ingress.start()
    const port = ingress.port()
    const body = await new Promise((resolve, reject) => {
      const request = http.get({
        host: '127.0.0.1',
        port,
        path: `/?dsh-auth=${credential}`,
        headers: { cookie: `dsh_swift_renderer=${state.rendererToken}` },
      }, (response) => {
        let output = ''
        response.setEncoding('utf8')
        response.on('data', (chunk) => { output += chunk })
        response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, output }))
      })
      request.on('error', reject)
    })
    assert.equal(body.status, 200)
    const forwarded = JSON.parse(body.output)
    assert.equal(forwarded.host, `127.0.0.1:${backendPort}`)
    const backendCredential = forwarded.cookie.match(/dsh_browser_auth=([^;]+)/)?.[1]
    assert.equal(typeof backendCredential, 'string')
    assert.equal(hasValidBrowserCredential({ url: '/', headers: { cookie: forwarded.cookie } }, state), true)
    assert.equal(
      decideRequest({ url: '/', headers: { host: `127.0.0.1:${backendPort}`, cookie: forwarded.cookie } }, state),
      CLASSIFICATIONS.browser,
    )
    assert.doesNotMatch(forwarded.cookie, /dsh_swift_renderer=/)
    assert.doesNotMatch(forwarded.cookie, /dsh_lan_auth=/)
    assert.equal(forwarded.url, '/')
    const lanCookie = body.headers['set-cookie'].find((cookie) => cookie.startsWith(`${LAN_COOKIE_NAME}=`))
    assert.match(lanCookie, new RegExp(`^${LAN_COOKIE_NAME}=${credential};`))
    assert.doesNotMatch(lanCookie, new RegExp(backendCredential))

    const secondBody = await new Promise((resolve, reject) => {
      const request = http.get({
        host: '127.0.0.1',
        port,
        path: '/',
        headers: { cookie: lanCookie.split(';', 1)[0] },
      }, (response) => {
        let output = ''
        response.setEncoding('utf8')
        response.on('data', (chunk) => { output += chunk })
        response.on('end', () => resolve({ status: response.statusCode, output }))
      })
      request.on('error', reject)
    })
    assert.equal(secondBody.status, 200)
    const secondForwarded = JSON.parse(secondBody.output)
    assert.equal(secondForwarded.cookie, forwarded.cookie)
    assert.equal(hasValidLanCredential({ url: '/', headers: { cookie: `dsh_browser_auth=${backendCredential}` } }, state), false)
  } finally {
    await ingress.stop()
    await new Promise((resolve) => backend.close(resolve))
  }
})

test('LAN ingress brokers B plus upstream U against the alpha.2 fixture while exposing only L', async (t) => {
  const fixture = await createUpstreamAuthFixture({ mode: 'alpha' })
  t.after(() => fixture.close())
  const state = managedState({ ordinaryBrowserEnabled: true })
  state.port = fixture.port
  state.networkExposure = NETWORK_EXPOSURES.lan
  const lanCredential = token()
  state.lanTokens.set(lanCredential, Date.now() + 60_000)
  const ingress = createLanHTTPIngress({
    backendPort: fixture.port,
    state,
    getConnection: () => ({
      authenticatedUrl(baseURL) {
        return `${baseURL}/?token=${encodeURIComponent(LAUNCH_TOKEN)}`
      },
    }),
    listenHost: '127.0.0.1',
    addressProvider: () => ['127.0.0.1'],
  })

  try {
    await ingress.start()
    const ingressPort = ingress.port()
    const first = await httpRequest({
      port: ingressPort,
      path: `/?dsh-auth=${lanCredential}`,
      host: `127.0.0.1:${ingressPort}`,
    })
    assert.equal(first.status, 200)
    assert.match(first.body, /DSH fixture/)
    const lanCookie = first.headers['set-cookie'].find((cookie) => cookie.startsWith(`${LAN_COOKIE_NAME}=`))
    assert.match(lanCookie, new RegExp(`^${LAN_COOKIE_NAME}=${lanCredential};`))
    assert.equal(first.headers['set-cookie'].some((cookie) => cookie.startsWith('dsh-auth-')), false)

    const observedAfterFirst = fixture.observed.slice()
    assert.equal(observedAfterFirst.length, 2)
    assert.match(observedAfterFirst[0].url, /token=fixture-launch-token/)
    assert.match(observedAfterFirst[0].cookie, /dsh_browser_auth=/)
    assert.doesNotMatch(observedAfterFirst[0].cookie, /dsh_lan_auth=|dsh_swift_renderer=|dsh-auth-/)
    assert.equal(observedAfterFirst[1].url, '/')
    assert.match(observedAfterFirst[1].cookie, /dsh_browser_auth=/)
    assert.match(observedAfterFirst[1].cookie, new RegExp(`${fixture.cookieName}=`))
    assert.doesNotMatch(observedAfterFirst[1].cookie, /dsh_lan_auth=|dsh_swift_renderer=/)

    const second = await httpRequest({
      port: ingressPort,
      path: '/api/health',
      cookie: lanCookie.split(';', 1)[0],
      host: `127.0.0.1:${ingressPort}`,
    })
    assert.equal(second.status, 200)
    assert.deepEqual(JSON.parse(second.body), { ok: true })
    assert.equal(fixture.observed.filter(({ url }) => url === '/?token=' + encodeURIComponent(LAUNCH_TOKEN)).length, 1)

    const upgradeHeader = await new Promise((resolve, reject) => {
      const socket = net.connect(ingressPort, '127.0.0.1')
      let output = ''
      socket.once('error', reject)
      socket.on('data', (chunk) => {
        output += chunk.toString('utf8')
        if (output.includes('\r\n\r\n')) {
          socket.destroy()
          resolve(output.slice(0, output.indexOf('\r\n\r\n')))
        }
      })
      socket.once('connect', () => socket.write([
        'GET /api/remote.mux HTTP/1.1',
        `Host: 127.0.0.1:${ingressPort}`,
        'Connection: Upgrade',
        'Upgrade: websocket',
        `Cookie: ${lanCookie.split(';', 1)[0]}`,
        '',
        '',
      ].join('\r\n')))
    })
    assert.match(upgradeHeader, /^HTTP\/1\.1 101 Switching Protocols/)
    const forwardedUpgrade = fixture.observed.at(-1)
    assert.equal(forwardedUpgrade.kind, 'upgrade')
    assert.match(forwardedUpgrade.cookie, new RegExp(`${fixture.cookieName}=`))
    assert.doesNotMatch(forwardedUpgrade.cookie, /dsh_lan_auth=|dsh_swift_renderer=/)
  } finally {
    await ingress.stop()
  }
})

test('LAN address discovery excludes loopback and keeps unique IPv4 addresses', () => {
  assert.deepEqual(
    getLanIPv4Addresses({
      en0: [
        { family: 'IPv4', address: '127.0.0.1', internal: true },
        { family: 'IPv4', address: '192.168.1.20', internal: false },
        { family: 'IPv4', address: '192.168.1.20', internal: false },
      ],
      en1: [
        { family: 'IPv4', address: '10.0.0.5', internal: false },
        { family: 'IPv4', address: '1.2.3.4', internal: false },
        { family: 'IPv6', address: 'fe80::1', internal: false },
      ],
    }),
    ['10.0.0.5', '192.168.1.20'],
  )
})

test('unmanaged CLI launches preserve upstream browser classification', () => {
  const state = createAccessState({ managedLaunch: false, port: 3187 })
  assert.equal(decideRequest(request({ host: 'localhost:3187' }), state), CLASSIFICATIONS.browser)
  assert.equal(requestPassesLoopbackFence(request({ host: 'localhost:3187' }), state), true)
})
