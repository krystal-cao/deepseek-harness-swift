import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  createUpstreamAuthFixture,
  LAUNCH_TOKEN,
  UPSTREAM_COOKIE,
} from "./fixtures/upstream-auth/server.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const contractPath = path.join(testDirectory, "fixtures", "upstream-auth", "runtime-contract.json");

function request({ port, path: requestPath, headers = {}, method = "GET" }) {
  return new Promise((resolve, reject) => {
    const requestObject = http.request({ host: "127.0.0.1", port, path: requestPath, method, headers }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    requestObject.on("error", reject);
    requestObject.end();
  });
}

function upgrade({ port, cookie }) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1");
    let response = "";
    const finish = () => {
      const headerEnd = response.indexOf("\r\n\r\n");
      resolve(headerEnd === -1 ? response : response.slice(0, headerEnd));
      socket.destroy();
    };
    socket.once("error", reject);
    socket.on("data", (chunk) => {
      response += chunk.toString("utf8");
      if (response.includes("\r\n\r\n")) finish();
    });
    socket.once("connect", () => {
      const lines = [
        "GET /api/remote.mux HTTP/1.1",
        `Host: 127.0.0.1:${String(port)}`,
        "Connection: Upgrade",
        "Upgrade: websocket",
        ...(cookie ? [`Cookie: ${cookie}`] : []),
        "",
        "",
      ];
      socket.write(lines.join("\r\n"));
    });
  });
}

test("P0 fixture records the checked rc.2, alpha.2, and alpha.3 package contracts", () => {
  const contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
  assert.deepEqual(contract.fixtures.map(({ runtime }) => runtime), ["0.1.1-rc.2", "0.1.2-alpha.2", "0.1.2-alpha.3"]);
  assert.equal(contract.fixtures[0].mode, "legacy");
  assert.equal(contract.fixtures[1].mode, "browserTokenCookie");
  assert.equal(contract.fixtures[2].mode, "browserTokenCookie");
  assert.match(contract.fixtures[1].dshIntegrity, /^sha512-/);
  assert.match(contract.fixtures[1].connectionIntegrity, /^sha512-/);
  assert.match(contract.fixtures[2].dshIntegrity, /^sha512-/);
  assert.match(contract.fixtures[2].connectionIntegrity, /^sha512-/);
});

test("alpha BrowserAuth is a token redirect followed by an upstream cookie", async (t) => {
  const fixture = await createUpstreamAuthFixture({ mode: "alpha" });
  t.after(() => fixture.close());
  const expectedCookieName = "dsh-auth-" + createHash("sha256")
    .update("127.0.0.1:" + String(fixture.port))
    .digest("base64url");
  assert.equal(fixture.cookieName, expectedCookieName);

  const anonymous = await request({ port: fixture.port, path: "/" });
  assert.equal(anonymous.status, 401);
  assert.match(anonymous.body, /dsh web authentication required/);

  const rendererOnly = await request({
    port: fixture.port,
    path: "/",
    headers: { cookie: "dsh_swift_renderer=renderer-only" },
  });
  assert.equal(rendererOnly.status, 401);

  const exchange = await request({
    port: fixture.port,
    path: `/?token=${encodeURIComponent(LAUNCH_TOKEN)}`,
    headers: { cookie: "dsh_swift_renderer=renderer-only" },
  });
  assert.equal(exchange.status, 303);
  assert.equal(exchange.headers.location, "/");
  assert.equal(exchange.headers["referrer-policy"], "no-referrer");
  assert.match(exchange.headers["set-cookie"]?.[0] ?? "", /^dsh-auth-[^=]+=.*HttpOnly/);

  const upstreamCookie = `${fixture.cookieName}=${UPSTREAM_COOKIE}`;
  const cleanPage = await request({
    port: fixture.port,
    path: "/",
    headers: { cookie: `dsh_swift_renderer=renderer-only; ${upstreamCookie}` },
  });
  assert.equal(cleanPage.status, 200);
  assert.match(cleanPage.body, /DSH fixture/);

  const api = await request({ port: fixture.port, path: "/api/health", headers: { cookie: upstreamCookie } });
  assert.equal(api.status, 200);
  assert.deepEqual(JSON.parse(api.body), { ok: true });

  const websocket = await upgrade({ port: fixture.port, cookie: upstreamCookie });
  assert.match(websocket, /^HTTP\/1\.1 101 Switching Protocols/);
});

test("alpha BrowserAuth rejects invalid or ambiguous token inputs and repeats valid exchange", async (t) => {
  const fixture = await createUpstreamAuthFixture({ mode: "alpha" });
  t.after(() => fixture.close());

  for (const path of [
    "/?token=wrong",
    "/?token=fixture-launch-token&token=fixture-launch-token",
    "/?token=",
  ]) {
    const response = await request({ port: fixture.port, path });
    assert.equal(response.status, 401, path);
  }

  const repeated = await request({ port: fixture.port, path: `/?token=${encodeURIComponent(LAUNCH_TOKEN)}` });
  assert.equal(repeated.status, 303);
});

test("rc.2 remains clean-origin compatible and does not require upstream auth", async (t) => {
  const fixture = await createUpstreamAuthFixture({ mode: "rc" });
  t.after(() => fixture.close());

  const page = await request({ port: fixture.port, path: "/" });
  assert.equal(page.status, 200);
  const api = await request({ port: fixture.port, path: "/api/health" });
  assert.equal(api.status, 200);
  const websocket = await upgrade({ port: fixture.port });
  assert.match(websocket, /^HTTP\/1\.1 101 Switching Protocols/);
});

test("upstream authority is bound to the exact host and port", async (t) => {
  const fixture = await createUpstreamAuthFixture({ mode: "alpha" });
  t.after(() => fixture.close());

  const wrongHost = await request({ port: fixture.port, path: "/", headers: { host: `localhost:${String(fixture.port)}` } });
  assert.equal(wrongHost.status, 421);
  const wrongPort = await request({ port: fixture.port, path: "/", headers: { host: `127.0.0.1:${String(fixture.port + 1)}` } });
  assert.equal(wrongPort.status, 421);
});
