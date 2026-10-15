import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { once } from 'node:events';
import { createApp } from '../src/app.js';
import { FileStore } from '../src/store.js';
import { PlaidClient } from '../src/plaid.js';
import { loadConfig } from '../src/config.js';
import { signTestToken } from '../src/auth.js';

const secret = 'test-jwt-secret-that-is-at-least-thirty-two-characters';
const encryptionKey = '11'.repeat(32);
const plaidError = (code, status = 502) => Object.assign(new Error(code), { code, status });
const tx = (id, account, amount = 10) => ({ transaction_id: id, account_id: account, name: id, amount, date: '2026-09-01', pending: false });

// Two Items whose behaviour each test can override.
class FakePlaid {
  constructor(overrides = {}) { this.calls = []; Object.assign(this, overrides); }
  async createLinkToken(user, accessToken) { this.calls.push(['link', accessToken]); return { link_token: `link-${user}`, expiration: '2030-01-01T00:00:00Z' }; }
  async exchange(token) { return { access_token: `access-${token}`, item_id: `item-${token}` }; }
  async accounts(token) { return { accounts: [{ account_id: `acct-${token}`, name: 'Checking', type: 'depository', subtype: 'checking', mask: '0001', balances: { current: 100, available: 90 } }] }; }
  async syncAll(token) { return { cursor: 'c1', added: [tx(`tx-${token}`, `acct-${token}`)], modified: [], removed: [] }; }
  async remove() { return {}; }
}

async function fixture(plaid) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'margin-reg-')), file = path.join(dir, 'data.json');
  const config = { plaidEnv: 'sandbox', plaidClientId: 'client', plaidSecret: 'secret', jwtSecret: secret, jwtIssuer: 'margin-test', jwtAudience: 'margin-bank-api' };
  const server = createApp({ config, plaid, store: new FileStore(file, encryptionKey) });
  server.listen(0); await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const token = signTestToken({ sub: 'matt', iss: 'margin-test', aud: 'margin-bank-api', exp: Math.floor(Date.now() / 1000) + 300 }, secret);
  const request = async (url, options = {}) => { const r = await fetch(base + url, { ...options, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...(options.headers || {}) } }); return { status: r.status, data: await r.json() }; };
  const link = publicToken => request('/v1/plaid/exchange', { method: 'POST', body: JSON.stringify({ publicToken }) });
  return { base, file, request, link, close: async () => { server.close(); await once(server, 'close'); await fs.rm(dir, { recursive: true, force: true }); } };
}

test('an Item is persisted even when the follow-up accounts call fails, so it can still be disconnected', async () => {
  const plaid = new FakePlaid({ async accounts() { throw plaidError('INTERNAL_SERVER_ERROR'); } });
  const f = await fixture(plaid);
  try {
    const linked = await f.link('a');
    assert.equal(linked.status, 201);
    assert.deepEqual(linked.data.accounts, []);
    assert.equal((await f.request('/v1/plaid/accounts')).data.connections.length, 1);
    assert.equal((await f.request('/v1/plaid/connections/item-a', { method: 'DELETE' })).status, 200);
  } finally { await f.close(); }
});

test('sync returns only the synced Item\'s transactions and refreshes balances', async () => {
  const plaid = new FakePlaid({ async syncAll(token) { return { cursor: 'c', added: [tx(`tx-${token}`, `acct-${token}`)], modified: [], removed: [], accounts: [{ account_id: `acct-${token}`, name: 'Checking', type: 'depository', mask: '0001', balances: { current: 555 } }] }; } });
  const f = await fixture(plaid);
  try {
    await f.link('a'); await f.link('b');
    await f.request('/v1/plaid/sync', { method: 'POST', body: JSON.stringify({ itemId: 'item-a' }) });
    const { data } = await f.request('/v1/plaid/sync', { method: 'POST', body: JSON.stringify({ itemId: 'item-b' }) });
    assert.deepEqual(data.transactions.map(t => t.id), ['tx-access-b']);
    assert.equal(data.accounts[0].currentBalance, 555);
    const b = (await f.request('/v1/plaid/accounts')).data.connections.find(c => c.itemId === 'item-b');
    assert.equal(b.accounts[0].currentBalance, 555);
  } finally { await f.close(); }
});

test('ITEM_LOGIN_REQUIRED is surfaced as requiresAttention and an update-mode link token can repair it', async () => {
  let broken = true;
  const plaid = new FakePlaid({ async syncAll(token) { if (broken) throw plaidError('ITEM_LOGIN_REQUIRED', 409); return { cursor: 'c', added: [], modified: [], removed: [] }; } });
  const f = await fixture(plaid);
  try {
    await f.link('a');
    assert.equal((await f.request('/v1/plaid/sync', { method: 'POST', body: JSON.stringify({ itemId: 'item-a' }) })).status, 409);
    assert.equal((await f.request('/v1/plaid/accounts')).data.connections[0].requiresAttention, true);
    await f.request('/v1/plaid/link-token', { method: 'POST', body: JSON.stringify({ itemId: 'item-a' }) });
    assert.deepEqual(plaid.calls.at(-1), ['link', 'access-a']);
    broken = false;
    await f.request('/v1/plaid/sync', { method: 'POST', body: JSON.stringify({ itemId: 'item-a' }) });
    assert.equal((await f.request('/v1/plaid/accounts')).data.connections[0].requiresAttention, false);
  } finally { await f.close(); }
});

test('disconnect still removes local data when Plaid already forgot the Item, but not on other failures', async () => {
  let code = 'INTERNAL_SERVER_ERROR';
  const f = await fixture(new FakePlaid({ async remove() { throw plaidError(code); } }));
  try {
    await f.link('a');
    assert.equal((await f.request('/v1/plaid/connections/item-a', { method: 'DELETE' })).status, 502);
    assert.equal((await f.request('/v1/plaid/accounts')).data.connections.length, 1);
    code = 'ITEM_NOT_FOUND';
    assert.equal((await f.request('/v1/plaid/connections/item-a', { method: 'DELETE' })).status, 200);
    assert.equal((await f.request('/v1/plaid/accounts')).data.connections.length, 0);
  } finally { await f.close(); }
});

test('routes ignore query strings and reject malformed connection ids', async () => {
  const f = await fixture(new FakePlaid());
  try {
    assert.equal((await f.request('/v1/plaid/accounts?refresh=1')).status, 200);
    assert.equal((await f.request('/v1/plaid/connections/%E0%A4%A', { method: 'DELETE' })).status, 400);
  } finally { await f.close(); }
});

test('sync restarts from the original cursor when Plaid reports a mutation during pagination', async () => {
  const cursors = []; let failOnce = true;
  const client = new PlaidClient({ plaidClientId: 'x', plaidSecret: 'y', plaidEnv: 'sandbox' });
  client.syncPage = async (_token, cursor) => {
    cursors.push(cursor);
    if (cursor === 'page-2' && failOnce) { failOnce = false; throw plaidError('TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION'); }
    return cursor === 'page-2' ? { added: [tx('t2', 'a')], modified: [], removed: [], next_cursor: 'end', has_more: false } : { added: [tx('t1', 'a')], modified: [], removed: [], next_cursor: 'page-2', has_more: true };
  };
  const result = await client.syncAll('token', 'start');
  assert.deepEqual(cursors, ['start', 'page-2', 'start', 'page-2']);
  assert.deepEqual(result.added.map(t => t.transaction_id), ['t1', 't2']);
  assert.equal(result.cursor, 'end');
});

test('config refuses to start without a usable encryption key in any environment', () => {
  assert.throws(() => loadConfig({ NODE_ENV: 'development' }), /TOKEN_ENCRYPTION_KEY/);
  assert.throws(() => loadConfig({ PLAID_ENV: 'development', TOKEN_ENCRYPTION_KEY: encryptionKey }), /PLAID_ENV/);
  assert.equal(loadConfig({ TOKEN_ENCRYPTION_KEY: encryptionKey }).plaidEnv, 'sandbox');
});

test('tokens with a non-HS256 alg or a future nbf are rejected', async () => {
  const f = await fixture(new FakePlaid());
  try {
    const exp = Math.floor(Date.now() / 1000) + 300, claims = { sub: 'matt', iss: 'margin-test', aud: 'margin-bank-api', exp };
    const none = Buffer.from(JSON.stringify({ alg: 'none' })).toString('base64url');
    const valid = signTestToken(claims, secret).split('.');
    const future = signTestToken({ ...claims, nbf: exp }, secret);
    for (const token of [`${none}.${valid[1]}.${valid[2]}`, future]) {
      const r = await fetch(`${f.base}/v1/plaid/accounts`, { headers: { authorization: `Bearer ${token}` } });
      assert.equal(r.status, 401);
    }
  } finally { await f.close(); }
});

test('non-numeric exp and Object.prototype names are rejected or isolated', async () => {
  const f = await fixture(new FakePlaid());
  try {
    const forever = signTestToken({ sub: 'matt', iss: 'margin-test', aud: 'margin-bank-api', exp: 'never' }, secret);
    const proto = signTestToken({ sub: 'toString', iss: 'margin-test', aud: 'margin-bank-api', exp: Math.floor(Date.now() / 1000) + 300 }, secret);
    for (const token of [forever, proto]) assert.equal((await fetch(`${f.base}/v1/plaid/accounts`, { headers: { authorization: `Bearer ${token}` } })).status, 401);
    assert.equal((await f.request('/v1/plaid/sync', { method: 'POST', body: JSON.stringify({ itemId: 'toString' }) })).status, 404);
  } finally { await f.close(); }
});

test('a sync past the page cap saves its progress and resumes, restarting from where the update began', async () => {
  const { PlaidClient, MAX_PAGES } = await import('../src/plaid.js');
  const client = new PlaidClient({ plaidClientId: 'id', plaidSecret: 'secret', plaidEnv: 'sandbox' });
  const calls = []; let mutateOnce = true;
  client.syncPage = async (_token, cursor) => {
    calls.push(cursor);
    const n = cursor === null ? 0 : Number(cursor.slice(1));
    if (n === MAX_PAGES + 2 && mutateOnce) { mutateOnce = false; throw plaidError('TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION'); }
    return { added: [tx(`t${n}`, 'a')], modified: [], removed: [], next_cursor: `p${n + 1}`, has_more: n + 1 < MAX_PAGES + 5 };
  };
  const first = await client.syncAll('token', null);
  assert.equal(first.hasMore, true);
  assert.equal(first.cursor, `p${MAX_PAGES}`);
  assert.equal(first.added.length, MAX_PAGES);
  // Resuming from the saved cursor; the mutation error must restart from the update's first cursor (null).
  calls.length = 0;
  const second = await client.syncAll('token', first.cursor, null);
  assert.equal(calls[0], `p${MAX_PAGES}`);
  assert.ok(calls.includes(null), 'restarted from the start of the update');
  assert.equal(second.hasMore, true);
});

test('applySync keeps the update start while more pages remain and drops a stale result', async () => {
  const { FileStore } = await import('../src/store.js');
  const { mkdtemp } = await import('node:fs/promises'); const { tmpdir } = await import('node:os'); const { join } = await import('node:path');
  const store = new FileStore(join(await mkdtemp(join(tmpdir(), 'margin-')), 'data.json'), 'a'.repeat(64));
  await store.saveItem('apple:u', { itemId: 'item', accessToken: 'tok', institutionName: 'Bank' }, 0);
  const page = (id, cursor, startCursor, hasMore) => ({ cursor, startCursor, hasMore, added: [tx(id, 'a')], modified: [], removed: [] });
  let r = await store.applySync('apple:u', 'item', page('t1', 'c20', null, true));
  assert.equal(r.hasMore, true);
  let item = (await store.getUser('apple:u')).items.item;
  assert.equal(item.cursor, 'c20'); assert.equal(item.paginationStart, null);
  // A slower sync that also started from null finishes now: it must not roll the cursor back.
  r = await store.applySync('apple:u', 'item', page('old', 'c5', null, false));
  item = (await store.getUser('apple:u')).items.item;
  assert.equal(item.cursor, 'c20'); assert.equal(r.added, 0);
  assert.ok(!r.transactions.some(t => t.transaction_id === 'old'));
  r = await store.applySync('apple:u', 'item', page('t2', 'c25', 'c20', false));
  item = (await store.getUser('apple:u')).items.item;
  assert.equal(item.cursor, 'c25'); assert.ok(!('paginationStart' in item)); assert.equal(r.hasMore, false);
});

test('a restarted update replaces what its unfinished first part saved, so a transaction removed meanwhile is gone', async () => {
  const { FileStore } = await import('../src/store.js');
  const { mkdtemp } = await import('node:fs/promises'); const { tmpdir } = await import('node:os'); const { join } = await import('node:path');
  const store = new FileStore(join(await mkdtemp(join(tmpdir(), 'margin-')), 'data.json'), 'a'.repeat(64));
  await store.saveItem('apple:u', { itemId: 'item', accessToken: 'tok', institutionName: 'Bank' }, 0);
  const base = { modified: [], removed: [] };
  // Part one of an update saves pending P; P then posts as T and Plaid restarts the update from null.
  await store.applySync('apple:u', 'item', { ...base, cursor: 'c20', startCursor: null, hasMore: true, added: [tx('P', 'a'), tx('A', 'a')] });
  const r = await store.applySync('apple:u', 'item', { ...base, cursor: 'end', startCursor: 'c20', hasMore: false, restarted: true, added: [tx('T', 'a'), tx('A', 'a')] });
  assert.deepEqual(r.transactions.map(t => t.transaction_id).sort(), ['A', 'T']);
  const item = (await store.getUser('apple:u')).items.item;
  assert.ok(!('paginationIds' in item) && !('paginationStart' in item));
});
