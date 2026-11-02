'use strict';

const assert = require('node:assert/strict');
const { after, mock } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const childProcess = require('node:child_process');

function setupServerEnvironment() {
  const tempRoot = path.resolve(os.tmpdir());
  const dir = fs.mkdtempSync(path.join(tempRoot, 'riff-test-'));
  const saved = new Map(['RIFF_DATA_DIR', 'LOCALAPPDATA', 'APPDATA', 'XDG_CONFIG_HOME']
    .map(key => [key, process.env[key]]));
  const blocked = [];

  for (const key of saved.keys()) process.env[key] = dir;
  mock.method(os, 'homedir', () => dir);

  function deny(operation) {
    return () => {
      blocked.push(operation);
      throw new Error(`Unexpected side effect in server test: ${operation}`);
    };
  }

  function onlyLoopback(original, operation) {
    return function (input, ...args) {
      const target = typeof input === 'string' ? new URL(input) : input;
      if ((target.protocol && target.protocol !== 'http:') ||
          (target.hostname || target.host) !== '127.0.0.1') {
        return deny(operation)();
      }
      return original.call(this, input, ...args);
    };
  }

  mock.method(http, 'request', onlyLoopback(http.request, 'external HTTP request'));
  mock.method(http, 'get', onlyLoopback(http.get, 'external HTTP GET'));
  mock.method(https, 'request', deny('unmocked HTTPS request'));
  mock.method(https, 'get', deny('unmocked HTTPS GET'));
  const originalFetch = globalThis.fetch;
  mock.method(globalThis, 'fetch', (input, ...args) => {
    const target = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    if (target.protocol !== 'http:' || target.hostname !== '127.0.0.1') return deny('external fetch')();
    return originalFetch(input, ...args);
  });
  for (const method of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
    mock.method(childProcess, method, deny(`child_process.${method}`));
  }

  const platform = require('../src/shared/platform');
  assert.equal(platform.DATA_DIR, dir);
  mock.method(platform, 'resolveBinary', () => null);
  const tools = require('../src/server/tools');
  mock.method(tools, 'updateYtDlpIfManaged', async () => false);
  mock.method(tools, 'ensureTools', deny('tool installation'));

  after(async () => {
    try {
      const server = require.cache[require.resolve('../src/server/server')];
      if (server) await server.exports.stopServer();
    } finally {
      mock.restoreAll();
      for (const [key, value] of saved) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
      assert.equal(path.dirname(dir), tempRoot);
      assert.ok(path.basename(dir).startsWith('riff-test-'));
      fs.rmSync(dir, { recursive: true, force: true });
    }
    assert.deepEqual(blocked, [], 'server tests attempted uncontrolled side effects');
  });

  return { dir };
}

module.exports = { setupServerEnvironment };
