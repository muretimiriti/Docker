const test = require('node:test');
const assert = require('node:assert/strict');

const path = require('path');
const { createApp } = require('../app');
const { createFakeUserModel } = require('./fakeUserModel');

function getRouteHandler(app, method, routePath) {
  const layer = app.router.stack.find(
    (l) => l.route && l.route.path === routePath && l.route.methods && l.route.methods[method]
  );
  assert.ok(layer, `route not found: ${method.toUpperCase()} ${routePath}`);
  // Express stores handlers in route.stack
  assert.ok(layer.route.stack.length >= 1, 'missing route handler');
  return layer.route.stack[0].handle;
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
  const handler = getRouteHandler(app, 'get', '/healthz');

  const req = { query: {}, body: {} };
  const res = createRes();
  await handler(req, res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { ok: true });
});

test('GET / sends registration template file', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handler = getRouteHandler(app, 'get', '/');

  const req = { query: {}, body: {} };
  const res = createRes();
  await handler(req, res);

  assert.equal(res.statusCode, 200);
  assert.ok(res.filePath, 'expected sendFile to be called');
  assert.equal(path.basename(res.filePath), 'register.html');
});

test('POST /register validates required fields', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handler = getRouteHandler(app, 'post', '/register');

  const req = { body: { name: 'A' } };
  const res = createRes();
  await handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.match(String(res.body), /Missing required fields/);
});

test('register then view profile escapes stored XSS', async () => {
  const UserModel = createFakeUserModel();
  const app = createApp({ UserModel });

  const register = getRouteHandler(app, 'post', '/register');
  const profile = getRouteHandler(app, 'get', '/profile');

  const xssName = '<script>alert(1)</script>';

  const regReq = { body: { name: xssName, email: 'xss@example.com', hobbies: 'h', location: 'loc' } };
  const regRes = createRes();
  await register(regReq, regRes);
  assert.equal(regRes.statusCode, 302);
  assert.match(regRes.headers.location, /^\/profile\?id=[a-f0-9]{24}$/);

  const id = new URL(regRes.headers.location, 'http://example.invalid').searchParams.get('id');
  const profReq = { query: { id } };
  const profRes = createRes();
  await profile(profReq, profRes);

  assert.equal(profRes.statusCode, 200);
  assert.match(String(profRes.body), /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.ok(!String(profRes.body).includes('<script>'));
});

test('GET /profile rejects invalid ids', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handler = getRouteHandler(app, 'get', '/profile');

  const req = { query: { id: 'not-an-id' } };
  const res = createRes();
  await handler(req, res);

  assert.equal(res.statusCode, 400);
});

test('POST /update rejects invalid ids', async () => {
  const app = createApp({ UserModel: createFakeUserModel() });
  const handler = getRouteHandler(app, 'post', '/update');

  const req = { body: { id: 'bad', name: 'n', email: 'e@e.com', location: 'l' } };
  const res = createRes();
  await handler(req, res);

  assert.equal(res.statusCode, 400);
});

test('POST /update enforces unique email', async () => {
  const UserModel = createFakeUserModel();
  const app = createApp({ UserModel });

  const register = getRouteHandler(app, 'post', '/register');
  const update = getRouteHandler(app, 'post', '/update');

  // Create two users.
  const r1req = { body: { name: 'U1', email: 'u1@example.com', hobbies: '', location: 'L' } };
  const r1res = createRes();
  await register(r1req, r1res);
  const id1 = new URL(r1res.headers.location, 'http://example.invalid').searchParams.get('id');

  const r2req = { body: { name: 'U2', email: 'u2@example.com', hobbies: '', location: 'L' } };
  const r2res = createRes();
  await register(r2req, r2res);
  assert.equal(r2res.statusCode, 302);

  const updReq = { body: { id: id1, name: 'U1', email: 'u2@example.com', hobbies: '', location: 'L' } };
  const updRes = createRes();
  await update(updReq, updRes);

  assert.equal(updRes.statusCode, 409);
});

