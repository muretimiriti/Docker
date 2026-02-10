const mongoose = require('mongoose');

const UserSchema = new mongoose.Schema({
  name: { type: String, required: true, trim: true },
  email: { type: String, required: true, trim: true, unique: true },
  hobbies: { type: String, trim: true },
  location: { type: String, required: true }
});

module.exports = mongoose.model('User', UserSchema);
