const test = require('node:test');
const assert = require('node:assert/strict');
const { createLoader } = require('./ets-loader.cjs');

function clientHarness() {
  let serial = 0;
  const load = createLoader({
    '@kit.NetworkKit': { http: {}, webSocket: {} },
    '@kit.ArkTS': { util: { generateRandomUUID: () => `fixture-${++serial}` } },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } }
  });
  const { NativeClient } = load('data/NativeClient');
  const calls = [];
  const client = new NativeClient();
  // The public RPC path is under test. Only connection readiness is established
  // in memory here; no real account, browser or system network is used.
  client.connected = true; client.clientId = 'fixture-client';
  client.carrier = {
    async rpc(endpoint, args) { calls.push({ endpoint, args }); throw new Error(this.code); },
    code: 'settings/conflict'
  };
  return { client, calls };
}

test('NativeClient preserves bounded settings/credential codes from carrier without replay', async () => {
  const { client, calls } = clientHarness();
  for (const code of ['settings/conflict', 'settings/rejected', 'credential/rejected', 'RPC_TIMEOUT']) {
    client.carrier.code = code;
    const before = calls.length;
    await assert.rejects(client.rpc('settings/mutate', '{"ns":"fixture","ops":[]}'), e => e.message === code);
    assert.equal(calls.length, before + 1);
    assert.equal(client.pendingCarrier.size, 0);
  }
});

test('NativeClient rejects arbitrary carrier messages and credential-bearing details', async () => {
  const { client } = clientHarness();
  for (const code of ['settings/conflict: secret-sentinel', 'https://fixture.invalid/?token=secret-sentinel', 'secret sentinel', 'x'.repeat(101), '']) {
    client.carrier.code = code;
    await assert.rejects(client.rpc('settings/describe'), e => e.message === 'CARRIER_FAILED');
  }
});
