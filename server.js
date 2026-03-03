const mongoose = require('mongoose');
const dotenv = require('dotenv');
const otel = require('./otel');
const logger = require('./logger');
const { createApp } = require('./app');

// Load environment variables from .env
dotenv.config();

// Connect to MongoDB
mongoose.connect(process.env.MONGO_URI)
.then(() => logger.info('mongodb_connected'))
.catch(err => logger.error('mongodb_connection_error', { error: err && err.message ? err.message : String(err) }));

const app = createApp();

// Start Server
const PORT = process.env.PORT || 3000;
const server = app.listen(PORT, () => {
  logger.info('server_started', { port: Number(PORT) });
});

process.on('SIGTERM', async () => {
  await otel.stop();
  server.close(() => process.exit(0));
});

process.on('SIGINT', async () => {
  await otel.stop();
  server.close(() => process.exit(0));
});
