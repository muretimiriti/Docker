const mongoose = require('mongoose');
const dotenv = require('dotenv');
const otel = require('./otel');
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
const server = app.listen(PORT, () => {
  console.log(`🚀 Server running on http://localhost:${PORT}`);
});

process.on('SIGTERM', async () => {
  await otel.stop();
  server.close(() => process.exit(0));
});

process.on('SIGINT', async () => {
  await otel.stop();
  server.close(() => process.exit(0));
});
