const express = require('express');
const mongoose = require('mongoose');
const dotenv = require('dotenv');
const bodyParser = require('body-parser');
const path = require('path');
const fs = require('fs');

// Load environment variables from .env
dotenv.config();

// Initialize express app
const app = express();

// Middleware
app.use(bodyParser.urlencoded({ extended: true }));
app.use(express.static('public'));

// Mongoose model
const User = require('./models/User');

// Connect to MongoDB
mongoose.connect(process.env.MONGO_URI, {
  useNewUrlParser: true,
  useUnifiedTopology: true
})
.then(() => console.log('✅ MongoDB connected'))
.catch(err => console.error('❌ MongoDB error:', err));

// ROUTES

// === GET: Registration Page ===
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'register.html'));
});

// === POST: Register New User ===
app.post('/register', async (req, res) => {
  const { name, email, hobbies, location } = req.body;

  try {
    const newUser = new User({ name, email, hobbies, location });
    await newUser.save();
    res.redirect(`/profile?id=${newUser._id}`);
  } catch (err) {
    console.error('Error saving user:', err);
    res.status(500).send('Error saving user');
  }
});

// === GET: Profile Page with Existing User Info ===
app.get('/profile', async (req, res) => {
  const userId = req.query.id;

  try {
    const user = await User.findById(userId).lean();
    if (!user) return res.status(404).send('User not found');

    // Load HTML template and inject values
    let template = fs.readFileSync(path.join(__dirname, 'views', 'profile.html'), 'utf-8');
    template = template
      .replace('{{id}}', user._id)
      .replace('{{name}}', user.name)
      .replace('{{email}}', user.email)
      .replace('{{hobbies}}', user.hobbies || '')
      .replace('{{location}}', user.location);

    res.send(template);
  } catch (err) {
    console.error('Error loading profile:', err);
    res.status(500).send('Server error');
  }
});

// === POST: Update User Info ===
app.post('/update', async (req, res) => {
  const { id, name, email, hobbies, location } = req.body;

  try {
    await User.findByIdAndUpdate(id, { name, email, hobbies, location });
    res.redirect(`/profile?id=${id}`);
  } catch (err) {
    console.error('Error updating user:', err);
    res.status(500).send('Error updating user');
  }
});

// Start Server
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 Server running on http://localhost:${PORT}`);
});
