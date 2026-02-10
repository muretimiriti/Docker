const crypto = require('crypto');

function createFakeUserModel() {
  const usersById = new Map();
  const idByEmail = new Map();

  class FakeUser {
    constructor({ name, email, hobbies, location } = {}) {
      this._id = crypto.randomBytes(12).toString('hex'); // 24-char hex
      this.name = name;
      this.email = email;
      this.hobbies = hobbies;
      this.location = location;
    }

    async save() {
      const existingId = idByEmail.get(this.email);
      if (existingId && existingId !== this._id) {
        const err = new Error('Duplicate email');
        err.code = 11000;
        throw err;
      }
      usersById.set(this._id, { ...this });
      idByEmail.set(this.email, this._id);
      return this;
    }

    static async findById(id) {
      const user = usersById.get(id);
      return user ? { ...user } : null;
    }

    static async findByIdAndUpdate(id, update) {
      const existing = usersById.get(id);
      if (!existing) return null;

      if (update && typeof update.email === 'string') {
        const otherId = idByEmail.get(update.email);
        if (otherId && otherId !== id) {
          const err = new Error('Duplicate email');
          err.code = 11000;
          throw err;
        }
        idByEmail.delete(existing.email);
        idByEmail.set(update.email, id);
      }

      const next = { ...existing, ...update, _id: id };
      usersById.set(id, next);
      return { ...next };
    }
  }

  return FakeUser;
}

module.exports = { createFakeUserModel };

