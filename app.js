const express = require('express');
const path = require('path');
const fs = require('fs');

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
    const { name, email, hobbies, location } = req.body;

    if (!name || !email || !location) {
      return res.status(400).send('Missing required fields');
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
  app.post('/update', async (req, res) => {
    const { id, name, email, hobbies, location } = req.body;

    if (!isValidObjectId(id)) {
      return res.status(400).send('Invalid user id');
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

  return app;
}

module.exports = {
  createApp,
  escapeHtml,
  isValidObjectId,
  renderProfile,
  loadTemplate
};
