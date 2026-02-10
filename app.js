const express = require('express');
const path = require('path');
const fs = require('fs');

function nowMs() {
  return Date.now();
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function isValidObjectId(id) {
  // Avoid throwing CastErrors when running with mongoose; also works for tests.
  return typeof id === 'string' && /^[a-fA-F0-9]{24}$/.test(id);
}

function loadTemplate(viewsDir, filename) {
  return fs.readFileSync(path.join(viewsDir, filename), 'utf-8');
}

function renderProfile(template, user) {
  // Keep template rendering tiny and fast; escape to prevent stored XSS.
  return template
    .replaceAll('{{id}}', escapeHtml(user._id))
    .replaceAll('{{name}}', escapeHtml(user.name))
    .replaceAll('{{email}}', escapeHtml(user.email))
    .replaceAll('{{hobbies}}', escapeHtml(user.hobbies || ''))
    .replaceAll('{{location}}', escapeHtml(user.location));
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isValidEmail(email) {
  if (typeof email !== 'string') return false;
  const e = email.trim();
  if (e.length < 3 || e.length > 254) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);
}

function normalizeText(value, maxLen) {
  if (value == null) return '';
  const s = String(value).trim();
  return s.length > maxLen ? s.slice(0, maxLen) : s;
}

function createFixedWindowRateLimiter({ windowMs, max, keyFn, message }) {
  const hits = new Map(); // key -> { count, resetAt }

  return function rateLimit(req, res, next) {
    const key = keyFn(req);
    const t = nowMs();
    const cur = hits.get(key);
    if (!cur || t >= cur.resetAt) {
      hits.set(key, { count: 1, resetAt: t + windowMs });
      return next();
    }

    cur.count += 1;
    if (cur.count > max) {
      res.setHeader('Retry-After', Math.ceil((cur.resetAt - t) / 1000));
      return res.status(429).send(message);
    }

    return next();
  };
}

function optionalBasicAuth({ userEnv, passEnv }) {
  const username = process.env[userEnv];
  const password = process.env[passEnv];
  const enabled = Boolean(username && password);

  return function maybeAuth(req, res, next) {
    if (!enabled) return next();

    const header = (req.headers && req.headers.authorization) || '';
    const [scheme, token] = header.split(' ');
    if (scheme !== 'Basic' || !token) {
      res.setHeader('WWW-Authenticate', 'Basic realm="update"');
      return res.status(401).send('Unauthorized');
    }

    let decoded = '';
    try {
      decoded = Buffer.from(token, 'base64').toString('utf8');
    } catch {
      res.setHeader('WWW-Authenticate', 'Basic realm="update"');
      return res.status(401).send('Unauthorized');
    }

    const idx = decoded.indexOf(':');
    const u = idx >= 0 ? decoded.slice(0, idx) : decoded;
    const p = idx >= 0 ? decoded.slice(idx + 1) : '';
    if (u !== username || p !== password) {
      res.setHeader('WWW-Authenticate', 'Basic realm="update"');
      return res.status(401).send('Unauthorized');
    }

    return next();
  };
}

/**
 * Create the Express app.
 *
 * Dependency injection is intentional:
 * - production uses the real Mongoose model
 * - tests can pass a fake model with the same method surface
 */
function createApp({ UserModel, viewsDir } = {}) {
  if (!UserModel) {
    // Lazy require to keep createApp flexible in tests.
    // eslint-disable-next-line global-require
    UserModel = require('./models/User');
  }

  viewsDir = viewsDir || path.join(__dirname, 'views');

  const app = express();

  // Middleware
  app.use(express.urlencoded({ extended: true }));
  app.use(express.static(path.join(__dirname, 'public')));

  // Basic in-memory rate limiting (demo-safe defaults).
  const keyFn = (req) =>
    req.ip ||
    (req.headers && (req.headers['x-forwarded-for'] || req.headers['X-Forwarded-For'])) ||
    'unknown';
  app.use(
    createFixedWindowRateLimiter({
      windowMs: 60 * 1000,
      max: 300,
      keyFn,
      message: 'Too many requests'
    })
  );

  const mutatingLimiter = createFixedWindowRateLimiter({
    windowMs: 60 * 1000,
    max: 30,
    keyFn,
    message: 'Too many requests'
  });

  // Template cache (avoids per-request disk IO).
  const registerTemplatePath = path.join(viewsDir, 'register.html');
  const profileTemplate = loadTemplate(viewsDir, 'profile.html');

  app.get('/healthz', (req, res) => {
    res.status(200).json({ ok: true });
  });

  // === GET: Registration Page ===
  app.get('/', (req, res) => {
    res.sendFile(registerTemplatePath);
  });

  // === POST: Register New User ===
  app.post('/register', async (req, res) => {
    mutatingLimiter(req, res, async () => {
      const name = normalizeText(req.body?.name, 100);
      const email = normalizeText(req.body?.email, 254);
      const hobbies = normalizeText(req.body?.hobbies, 200);
      const location = normalizeText(req.body?.location, 100);

      if (!isNonEmptyString(name) || !isNonEmptyString(location) || !isValidEmail(email)) {
        return res.status(400).send('Invalid input');
      }

      try {
        const newUser = new UserModel({ name, email, hobbies, location });
        await newUser.save();
        return res.redirect(`/profile?id=${newUser._id}`);
      } catch (err) {
        // Duplicate key on unique email
        if (err && err.code === 11000) {
          return res.status(409).send('Email already exists');
        }
        // eslint-disable-next-line no-console
        console.error('Error saving user:', err);
        return res.status(500).send('Error saving user');
      }
    });
  });

  // === GET: Profile Page with Existing User Info ===
  app.get('/profile', async (req, res) => {
    const userId = req.query.id;
    if (!isValidObjectId(userId)) {
      return res.status(400).send('Invalid user id');
    }

    try {
      const queryOrPromise = UserModel.findById(userId);
      const user = typeof queryOrPromise?.lean === 'function'
        ? await queryOrPromise.lean()
        : await queryOrPromise;
      if (!user) return res.status(404).send('User not found');
      return res.send(renderProfile(profileTemplate, user));
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error('Error loading profile:', err);
      return res.status(500).send('Server error');
    }
  });

  // === POST: Update User Info ===
  app.post(
    '/update',
    optionalBasicAuth({ userEnv: 'UPDATE_BASIC_AUTH_USER', passEnv: 'UPDATE_BASIC_AUTH_PASS' }),
    async (req, res) => {
      mutatingLimiter(req, res, async () => {
        const id = normalizeText(req.body?.id, 24);
        const name = normalizeText(req.body?.name, 100);
        const email = normalizeText(req.body?.email, 254);
        const hobbies = normalizeText(req.body?.hobbies, 200);
        const location = normalizeText(req.body?.location, 100);

        if (!isValidObjectId(id)) {
          return res.status(400).send('Invalid user id');
        }

        if (!isNonEmptyString(name) || !isNonEmptyString(location) || !isValidEmail(email)) {
          return res.status(400).send('Invalid input');
        }

        try {
          // Ensure validators run for Mongoose (noop for fakes).
          await UserModel.findByIdAndUpdate(
            id,
            { name, email, hobbies, location },
            { runValidators: true }
          );
          return res.redirect(`/profile?id=${id}`);
        } catch (err) {
          if (err && err.code === 11000) {
            return res.status(409).send('Email already exists');
          }
          // eslint-disable-next-line no-console
          console.error('Error updating user:', err);
          return res.status(500).send('Error updating user');
        }
      });
    }
  );

  return app;
}

module.exports = {
  createApp,
  escapeHtml,
  isValidObjectId,
  renderProfile,
  loadTemplate,
  createFixedWindowRateLimiter,
  optionalBasicAuth
};
