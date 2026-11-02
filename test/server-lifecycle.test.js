'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');

require('../test-support/server-environment').setupServerEnvironment();
const { startServer, stopServer } = require('../src/server/server');

test.afterEach(() => stopServer());

test('stop is idempotent and a failed start does not poison the next start', async () => {
  await stopServer();
  await stopServer();
  await assert.rejects(startServer(-1), { code: 'ERR_SOCKET_BAD_PORT' });
  assert.ok(await startServer(0) > 0);
});

test('repeated start returns the existing bound port', async () => {
  const first = await startServer(0);
  assert.equal(await startServer(0), first);
});

test('shutdown waits for a pending start and releases its port', { timeout: 5000 }, async () => {
  const starting = startServer(0);
  assert.equal(startServer(0), starting);
  const stopping = stopServer();
  const port = await starting;
  await stopping;
  const probe = http.createServer();
  try {
    await new Promise((resolve, reject) => {
      probe.once('error', reject);
      probe.listen(port, '127.0.0.1', resolve);
    });
  } finally {
    await new Promise(resolve => probe.close(resolve));
  }
  assert.equal(await startServer(port), port);
});

test('an occupied port falls back to an ephemeral loopback port', async () => {
  const occupied = http.createServer();
  await new Promise((resolve, reject) => {
    occupied.once('error', reject);
    occupied.listen(0, '127.0.0.1', resolve);
  });
  try {
    const reserved = occupied.address().port;
    const actual = await startServer(reserved);
    assert.ok(actual > 0);
    assert.notEqual(actual, reserved);
  } finally {
    await new Promise(resolve => occupied.close(resolve));
  }
});

test('shutdown closes an SSE connection and releases the port for restart', { timeout: 5000 }, async () => {
  const port = await startServer(0);
  const response = await new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path: '/api/lyrics-stream' }, res => {
      res.on('error', () => {});
      res.once('data', () => resolve(res));
    }).on('error', reject);
  });
  const closed = new Promise(resolve => response.once('close', resolve));
  await stopServer();
  await closed;
  assert.equal(await startServer(port), port);
});

test('repeated start and stop do not accumulate startup error listeners', async () => {
  const warnings = [];
  const onWarning = warning => warnings.push(warning);
  process.on('warning', onWarning);
  try {
    for (let i = 0; i < 15; i++) {
      await startServer(0);
      await stopServer();
    }
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(warnings.filter(warning => warning.name === 'MaxListenersExceededWarning').length, 0);
  } finally {
    process.removeListener('warning', onWarning);
  }
});
