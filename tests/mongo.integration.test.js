const test = require('node:test');
const assert = require('node:assert/strict');
const mongoose = require('mongoose');
const { MongoMemoryServer } = require('mongodb-memory-server');

const User = require('../models/User');

test('mongoose can write and read a user document against MongoDB', async () => {
  const mongod = await MongoMemoryServer.create();
  const uri = mongod.getUri();

  try {
    await mongoose.connect(uri);

    const created = await User.create({
      name: 'Integration User',
      email: `integration-${Date.now()}@example.com`,
      hobbies: 'testing',
      location: 'Nairobi'
    });

    const found = await User.findById(created._id).lean();
    assert.ok(found);
    assert.equal(found.name, 'Integration User');
    assert.equal(found.location, 'Nairobi');
  } finally {
    await mongoose.disconnect();
    await mongod.stop();
  }
});
