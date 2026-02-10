module.exports = {
  root: true,
  env: {
    node: true,
    es2022: true
  },
  parserOptions: {
    ecmaVersion: 2022
  },
  extends: ['eslint:recommended'],
  ignorePatterns: ['node_modules/', 'coverage/'],
  rules: {
    'no-unused-vars': ['error', { argsIgnorePattern: '^_' }]
  }
};

