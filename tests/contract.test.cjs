const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');

const root = path.join(__dirname, '..');

/** Runs a module from src/ as it is, transpiled to CommonJS: no build needed. */
function load(name) {
  const source = fs.readFileSync(path.join(root, 'src', `${name}.ts`), 'utf8');
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017 },
  });
  const module = { exports: {} };
  new Function('module', 'exports', 'require', outputText)(module, module.exports, (id) =>
    id.startsWith('.') ? load(id.slice(2)) : require(id),
  );
  return module.exports;
}

const { withContract } = load('contract');

/** A native side that records what reaches it and answers every call. */
function fixture() {
  const calls = [];
  const target = {};
  const native = new Proxy(target, {
    get(_, method) {
      if (method === 'then') return undefined;
      return async (options) => {
        calls.push({ method, options });
        return { method };
      };
    },
  });
  return { plugin: withContract(native), calls };
}

async function rejects(promise, message) {
  await assert.rejects(promise, (error) => {
    assert.equal(error.code, 'INVALID_ARGUMENT');
    if (message) assert.match(error.message, message);
    return true;
  });
}

test('valid options reach the native side unchanged', async () => {
  const { plugin, calls } = fixture();
  await plugin.connect({ ipAddress: '192.168.1.10', port: 9100, timeout: 5 });
  await plugin.send({ client: 0, data: 'aGVsbG8=', timeout: 0 });
  await plugin.read({ client: 0, expectLen: 512, timeout: 0 });
  await plugin.disconnect({ client: 0 });
  await plugin.listen({ port: 0 });
  await plugin.stopListening({ server: 0 });
  assert.deepEqual(calls, [
    { method: 'connect', options: { ipAddress: '192.168.1.10', port: 9100, timeout: 5 } },
    { method: 'send', options: { client: 0, data: 'aGVsbG8=', timeout: 0 } },
    { method: 'read', options: { client: 0, expectLen: 512, timeout: 0 } },
    { method: 'disconnect', options: { client: 0 } },
    { method: 'listen', options: { port: 0 } },
    { method: 'stopListening', options: { server: 0 } },
  ]);
});

test('omitted optional fields are left to the native defaults', async () => {
  const { plugin, calls } = fixture();
  await plugin.connect({ ipAddress: 'printer.local' });
  await plugin.read({ client: 1 });
  await plugin.listen();
  assert.deepEqual(calls[0].options, { ipAddress: 'printer.local', port: undefined, timeout: undefined });
  assert.deepEqual(calls[1].options, { client: 1, expectLen: undefined, timeout: undefined });
  assert.deepEqual(calls[2].options, { port: undefined });
});

test('invalid options reject asynchronously and never reach the native side', async () => {
  const { plugin, calls } = fixture();
  const pending = plugin.connect({});
  assert.ok(pending instanceof Promise);
  await rejects(pending, /Must provide ip address/);
  await rejects(plugin.connect('192.168.1.10'), /Options must be an object/);
  await rejects(plugin.send([]), /Options must be an object/);
  assert.equal(calls.length, 0);
});

test('connect checks host, port and timeout', async () => {
  const { plugin } = fixture();
  await rejects(plugin.connect({ ipAddress: '' }), /Must provide ip address/);
  await rejects(plugin.connect({ ipAddress: 42 }), /Must provide ip address/);
  await rejects(plugin.connect({ ipAddress: ' 192.168.1.10' }), /Invalid ip address/);
  for (const port of [0, -1, 65536, 1.5, '9100', NaN]) {
    await rejects(plugin.connect({ ipAddress: '10.0.0.1', port }), /Port out of range/);
  }
  for (const timeout of [-1, 0.5, '10', Infinity]) {
    await rejects(plugin.connect({ ipAddress: '10.0.0.1', timeout }), /timeout/);
  }
});

test('a huge timeout is clamped, not refused', async () => {
  const { plugin, calls } = fixture();
  await plugin.connect({ ipAddress: '10.0.0.1', timeout: 10 ** 12 });
  assert.equal(calls[0].options.timeout, 2147483647);
});

test('ids must be non-negative integers', async () => {
  const { plugin } = fixture();
  await rejects(plugin.read({}), /No client specified/);
  await rejects(plugin.disconnect({ client: null }), /No client specified/);
  await rejects(plugin.stopListening({}), /No server specified/);
  for (const client of [-1, 0.5, '0', 2 ** 31]) {
    await rejects(plugin.send({ client, data: '' }), /Invalid client index/);
  }
  await rejects(plugin.stopListening({ server: -1 }), /Invalid server index/);
});

test('read checks expectLen', async () => {
  const { plugin } = fixture();
  for (const expectLen of [0, -5, 1.5, '1024']) {
    await rejects(plugin.read({ client: 0, expectLen }), /expectLen/);
  }
});

test('listen accepts port 0 and rejects ports out of range', async () => {
  const { plugin, calls } = fixture();
  await plugin.listen({ port: 0 });
  await plugin.listen({ port: 65535 });
  await rejects(plugin.listen({ port: 65536 }), /Port out of range/);
  await rejects(plugin.listen({ port: -1 }), /Port out of range/);
  assert.equal(calls.length, 2);
});

test('send normalises base64 so every platform decodes it alike', async () => {
  const { plugin, calls } = fixture();
  await plugin.send({ client: 0, data: 'aGVs\nbG8g d29y bGQ=' });
  await plugin.send({ client: 0, data: 'YWI' });
  await plugin.send({ client: 0, data: 'YQ' });
  await plugin.send({ client: 0, data: '' });
  assert.deepEqual(
    calls.map((call) => call.options.data),
    ['aGVsbG8gd29ybGQ=', 'YWI=', 'YQ==', ''],
  );
});

test('send rejects data that is not base64', async () => {
  const { plugin } = fixture();
  await rejects(plugin.send({ client: 0 }), /No data provided/);
  for (const data of [42, 'YWJjZ', 'YW=J', 'YWI=a', 'ab=', 'aGVsbG8-', 'aGVsbG8_']) {
    await rejects(plugin.send({ client: 0, data }), /Invalid base64 data/);
  }
});

test('a payload of several megabytes is checked without overflowing the stack', async () => {
  const { plugin, calls } = fixture();
  const data = Buffer.alloc(8 * 1024 * 1024, 7).toString('base64');
  await plugin.send({ client: 0, data });
  assert.equal(calls[0].options.data.length, data.length);
});

test('listeners and methods without options pass straight through', async () => {
  const { plugin, calls } = fixture();
  await plugin.addListener('connection', () => undefined);
  await plugin.getLocalAddress();
  await plugin.removeAllListeners();
  assert.deepEqual(
    calls.map((call) => call.method),
    ['addListener', 'getLocalAddress', 'removeAllListeners'],
  );
  assert.equal(plugin.then, undefined);
});

test('the browser rejects with UNIMPLEMENTED', async () => {
  const { TcpSocketWeb } = load('web');
  const web = new TcpSocketWeb();
  for (const method of ['connect', 'send', 'read', 'disconnect', 'listen', 'stopListening']) {
    await assert.rejects(web[method]({}), (error) => error.code === 'UNIMPLEMENTED');
  }
  assert.deepEqual(await web.getLocalAddress(), {});
});

test('every code a platform rejects with is declared in TcpSocketErrorCode', () => {
  const definitions = fs.readFileSync(path.join(root, 'src/definitions.ts'), 'utf8');
  const union = definitions.match(/export type TcpSocketErrorCode =([^;]+);/)[1];
  const declared = new Set(union.match(/'([A-Z_]+)'/g).map((code) => code.slice(1, -1)));

  const sources = {
    ios: ['ios/Plugin/TcpSocketPlugin.swift', /static let \w+ = "([A-Z_]+)"/g],
    android: [
      'android/src/main/java/com/svend/plugins/tcp/socket/TcpSocketPlugin.java',
      /static final String ERR_\w+ = "([A-Z_]+)"/g,
    ],
    electron: ['electron/src/index.ts', /codedError\('([A-Z_]+)'/g],
  };
  for (const [platform, [file, pattern]] of Object.entries(sources)) {
    const used = [...fs.readFileSync(path.join(root, file), 'utf8').matchAll(pattern)].map((match) => match[1]);
    assert.ok(used.length > 0, `${platform}: no error codes found in ${file}`);
    for (const code of used) {
      assert.ok(declared.has(code), `${platform} rejects with ${code}, which TcpSocketErrorCode does not declare`);
    }
  }
});

test('every native rejection carries a code', () => {
  const read = (file) => fs.readFileSync(path.join(root, file), 'utf8').split('\n');
  const uncoded = [
    ...read('ios/Plugin/TcpSocketPlugin.swift')
      .map((line, index) => ['ios', index + 1, line])
      .filter(([, , line]) => line.includes('call.reject(') && !line.includes('ErrorCode.')),
    ...read('android/src/main/java/com/svend/plugins/tcp/socket/TcpSocketPlugin.java')
      .map((line, index) => ['android', index + 1, line])
      .filter(([, , line]) => line.includes('call.reject(') && !/, ERR_[A-Z_]+\)/.test(line)),
    // Every error Electron throws or rejects with is made by codedError.
    ...read('electron/src/index.ts')
      .map((line, index) => ['electron', index + 1, line])
      .filter(([, , line]) => /new Error\(/.test(line) && !line.includes('Object.assign(new Error(')),
  ];
  assert.deepEqual(
    uncoded.map(([platform, line, text]) => `${platform}:${line}: ${text.trim()}`),
    [],
  );
});
