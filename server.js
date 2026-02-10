const mongoose = require('mongoose');
const dotenv = require('dotenv');
const { createApp } = require('./app');

// Load environment variables from .env
dotenv.config();

// Connect to MongoDB
mongoose.connect(process.env.MONGO_URI)
.then(() => console.log('✅ MongoDB connected'))
.catch(err => console.error('❌ MongoDB error:', err));

const app = createApp();

// Start Server
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 Server running on http://localhost:${PORT}`);
});
