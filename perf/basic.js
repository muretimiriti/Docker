/* eslint-disable no-console */
const path = require('path');
const { performance } = require('perf_hooks');

const { loadTemplate, renderProfile } = require('../app');

function main() {
  const viewsDir = path.join(__dirname, '..', 'views');
  const template = loadTemplate(viewsDir, 'profile.html');

  const user = {
    _id: '0123456789abcdef01234567',
    name: '<script>alert(1)</script> Jane Doe',
    email: 'jane@example.com',
    hobbies: 'Reading, Swimming, Hiking',
    location: 'Nairobi'
  };

  // Micro-benchmark: template rendering should stay fast and allocation-light.
  const iters = 200000;
  const t0 = performance.now();
  let last = '';
  for (let i = 0; i < iters; i++) {
    last = renderProfile(template, user);
  }
  const ms = performance.now() - t0;
  const opsPerSec = Math.round((iters / ms) * 1000);

  if (!last.includes('&lt;script&gt;')) {
    throw new Error('renderProfile did not escape HTML as expected');
  }

  console.log(
    JSON.stringify(
      {
        benchmark: 'renderProfile',
        iterations: iters,
        durationMs: Math.round(ms),
        opsPerSec,
        memory: process.memoryUsage()
      },
      null,
      2
    )
  );

  // Very conservative threshold, intended to catch accidental quadratic work.
  if (opsPerSec < 20000) {
    throw new Error(`perf regression: renderProfile too slow (${opsPerSec} ops/sec)`);
  }
}

try {
  main();
} catch (err) {
  console.error(err);
  process.exit(1);
}

