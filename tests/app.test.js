const test = require('node:test');
const assert = require('node:assert/strict');

const path = require('path');
const { createApp } = require('../app');
const { createFakeUserModel } = require('./fakeUserModel');

function getRouteHandlers(app, method, routePath) {
  const layer = app.router.stack.find(
    (l) => l.route && l.route.path === routePath && l.route.methods && l.route.methods[method]
  );
  assert.ok(layer, `route not found: ${method.toUpperCase()} ${routePath}`);
  assert.ok(layer.route.stack.length >= 1, 'missing route handler');
  return layer.route.stack.map((s) => s.handle);
}

async function runHandlers(handlers, req, res) {
  let idx = 0;
  const next = async (err) => {
    if (err) throw err;
    const h = handlers[idx++];
    if (!h) return;
    if (h.length >= 3) {
      // middleware signature: (req, res, next)
      return h(req, res, next);
    }
    return h(req, res);
  };
  return next();
}

function createRes() {
  return {
    statusCode: 200,
    headers: {},
    body: undefined,
    filePath: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(obj) {
      this.body = obj;
      return this;
    },
    send(body) {
      this.body = body;
      return this;
    },
    sendFile(filePath) {
      this.filePath = filePath;
      return this;
    },
    redirect(location) {
      this.statusCode = 302;
      this.headers.location = location;
      return this;
    }
  };
}

test('GET /healthz returns ok', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handlers = getRouteHandlers(app, 'get', '/healthz');

  const req = { query: {}, body: {} };
  const res = createRes();
  await runHandlers(handlers, req, res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { ok: true });
});

test('GET / sends registration template file', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handlers = getRouteHandlers(app, 'get', '/');

  const req = { query: {}, body: {} };
  const res = createRes();
  await runHandlers(handlers, req, res);

  assert.equal(res.statusCode, 200);
  assert.ok(res.filePath, 'expected sendFile to be called');
  assert.equal(path.basename(res.filePath), 'register.html');
});

test('POST /register validates required fields', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handlers = getRouteHandlers(app, 'post', '/register');

  const req = { body: { name: 'A' } };
  const res = createRes();
  await runHandlers(handlers, req, res);

  assert.equal(res.statusCode, 400);
});

test('register then view profile escapes stored XSS', async () => {
  const UserModel = createFakeUserModel();
  const app = createApp({ UserModel });

  const register = getRouteHandlers(app, 'post', '/register');
  const profile = getRouteHandlers(app, 'get', '/profile');

  const xssName = '<script>alert(1)</script>';

  const regReq = { body: { name: xssName, email: 'xss@example.com', hobbies: 'h', location: 'loc' } };
  const regRes = createRes();
  await runHandlers(register, regReq, regRes);
  assert.equal(regRes.statusCode, 302);
  assert.match(regRes.headers.location, /^\/profile\?id=[a-f0-9]{24}$/);

  const id = new URL(regRes.headers.location, 'http://example.invalid').searchParams.get('id');
  const profReq = { query: { id } };
  const profRes = createRes();
  await runHandlers(profile, profReq, profRes);

  assert.equal(profRes.statusCode, 200);
  assert.match(String(profRes.body), /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.ok(!String(profRes.body).includes('<script>'));
});

test('GET /profile rejects invalid ids', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handlers = getRouteHandlers(app, 'get', '/profile');

  const req = { query: { id: 'not-an-id' } };
  const res = createRes();
  await runHandlers(handlers, req, res);

  assert.equal(res.statusCode, 400);
});

test('POST /update rejects invalid ids', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handlers = getRouteHandlers(app, 'post', '/update');

  const req = { body: { id: 'bad', name: 'n', email: 'e@e.com', location: 'l' } };
  const res = createRes();
  await runHandlers(handlers, req, res);

  assert.equal(res.statusCode, 400);
});

test('POST /update enforces unique email', async () => {
  const UserModel = createFakeUserModel();
  const app = createApp({ UserModel });

  const register = getRouteHandlers(app, 'post', '/register');
  const update = getRouteHandlers(app, 'post', '/update');

  // Create two users.
  const r1req = { body: { name: 'U1', email: 'u1@example.com', hobbies: '', location: 'L' } };
  const r1res = createRes();
  await runHandlers(register, r1req, r1res);
  const id1 = new URL(r1res.headers.location, 'http://example.invalid').searchParams.get('id');

  const r2req = { body: { name: 'U2', email: 'u2@example.com', hobbies: '', location: 'L' } };
  const r2res = createRes();
  await runHandlers(register, r2req, r2res);
  assert.equal(r2res.statusCode, 302);

  const updReq = { body: { id: id1, name: 'U1', email: 'u2@example.com', hobbies: '', location: 'L' } };
  const updRes = createRes();
  await runHandlers(update, updReq, updRes);

  assert.equal(updRes.statusCode, 409);
});
