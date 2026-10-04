import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { once } from 'node:events';
import { createApp, retryPendingAppleRevocations } from '../src/app.js';
import { FileStore } from '../src/store.js';
import { PlaidClient } from '../src/plaid.js';
import { signTestToken } from '../src/auth.js';
import { loadConfig } from '../src/config.js';
import { AppleIdentityVerifier, AppleTokenClient, sha256Hex, idTokenSubject } from '../src/apple.js';
import { createAskLimiter, readAnswer, isAskContext } from '../src/assistant.js';

const secret = 'test-jwt-secret-that-is-at-least-thirty-two-characters';
const encryptionKey = '11'.repeat(32);
const bundleId = 'com.margin.app';
const T = 1_800_000_000; // fixed clock (epoch seconds): every request in a test happens in the same second
const ENDED = 'Your session has ended. Sign in again.';
const plaidError = (code, status = 502) => Object.assign(new Error(code), { code, status });
const snapshot = { verdict: 'fitsNextMonth', price: 480 };
const DAY_MS = 24 * 60 * 60 * 1000;
const claimsOf = token => JSON.parse(Buffer.from(token.split('.')[1], 'base64url'));
// An id_token as Apple's token endpoint returns it; the app only reads its payload.
const idTokenFor = sub => [{ alg: 'RS256', kid: 'k' }, { iss: 'https://appleid.apple.com', aud: bundleId, sub }].map(part => Buffer.from(JSON.stringify(part)).toString('base64url')).concat('sig').join('.');

class FakePlaid {
  constructor(overrides = {}) { this.removedTokens = []; Object.assign(this, overrides); }
  async createLinkToken(user) { return { link_token: `link-${user}`, expiration: '2030-01-01T00:00:00Z' }; }
  async exchange(token) { return { access_token: `access-${token}`, item_id: `item-${token}` }; }
  async accounts() { return { accounts: [] }; }
  async syncAll() { return { cursor: 'c', added: [], modified: [], removed: [] }; }
  async remove(token) { this.removedTokens.push(token); return {}; }
}
// Stand-in for AppleIdentityVerifier: the identity token is just the Apple sub.
const fakeApple = { async verify(identityToken) { return { sub: identityToken }; } };

async function fixture({ plaid = new FakePlaid(), store: wrap = s => s, config: extra = {}, clock = { s: T }, ...options } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'margin-hard-')), file = path.join(dir, 'data.json');
  const config = { plaidEnv: 'sandbox', plaidClientId: 'client', plaidSecret: 'secret', jwtSecret: secret, jwtIssuer: 'margin-test', jwtAudience: 'margin-bank-api', appleBundleId: bundleId, sessionTtlDays: 30, ...extra };
  const store = wrap(new FileStore(file, encryptionKey));
  const server = createApp({ config, plaid, store, apple: fakeApple, now: () => clock.s * 1000, ...options });
  server.listen(0); await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const session = (sub = 'matt', iat = clock.s) => signTestToken({ sub, iss: 'margin-test', aud: 'margin-bank-api', ...(iat === null ? {} : { iat }), exp: clock.s + 300 }, secret);
  const call = async (url, { auth = session(), ...rest } = {}) => { const r = await fetch(base + url, { ...rest, headers: { 'content-type': 'application/json', ...(auth ? { authorization: `Bearer ${auth}` } : {}) } }); return { status: r.status, data: await r.json() }; };
  const post = (url, payload, options = {}) => call(url, { method: 'POST', body: JSON.stringify(payload), ...options });
  const signIn = async (sub, extraBody = {}) => { const r = await post('/v1/auth/apple', { identityToken: sub, nonce: 'n', ...extraBody }, { auth: null }); assert.equal(r.status, 200, JSON.stringify(r.data)); return r.data.sessionToken; };
  const readDisk = async () => JSON.parse(await fs.readFile(file, 'utf8'));
  return { file, store, clock, session, call, post, signIn, readDisk, close: async () => { server.close(); await once(server, 'close'); await fs.rm(dir, { recursive: true, force: true }); } };
}
const quietly = async (fn, sink = []) => { const original = console.warn; console.warn = (...args) => sink.push(args.join(' ')); try { return await fn(); } finally { console.warn = original; } };

// ---- 1. Ask Margin cost controls ----

test('readAnswer returns partial text at max_tokens and 502s when nothing was written', () => {
  assert.equal(readAnswer({ stop_reason: 'max_tokens', content: [{ type: 'thinking', thinking: '' }, { type: 'text', text: 'It fits if' }] }), 'It fits if');
  assert.throws(() => readAnswer({ stop_reason: 'max_tokens', content: [{ type: 'thinking', thinking: '' }] }), { status: 502, expose: true, message: 'Ask Margin could not answer right now' });
});

test('a global daily cap stops Ask Margin at capacity and hands the user slot back', async () => {
  const askLimiter = createAskLimiter({ limit: 1 });
  const answered = [];
  const f = await fixture({ assistant: { async answer({ question }) { answered.push(question); return 'ok'; } }, askLimiter, config: { askDailyGlobalLimit: 2 } });
  try {
    assert.equal((await f.post('/v1/ask', { question: 'a', context: snapshot }, { auth: f.session('matt') })).status, 200);
    assert.equal((await f.post('/v1/ask', { question: 'b', context: snapshot }, { auth: f.session('ana') })).status, 200);
    const full = await f.post('/v1/ask', { question: 'c', context: snapshot }, { auth: f.session('bob') });
    assert.deepEqual(full, { status: 429, data: { error: 'Ask Margin is at capacity today' } });
    assert.deepEqual(answered, ['a', 'b']);
    assert.equal(askLimiter.take('bob'), true, "bob's per-user slot was released");
  } finally { await f.close(); }
  assert.equal(loadConfig({ TOKEN_ENCRYPTION_KEY: encryptionKey }).askDailyGlobalLimit, 2000);
  assert.equal(loadConfig({ TOKEN_ENCRYPTION_KEY: encryptionKey, ASK_DAILY_GLOBAL_LIMIT: '50' }).askDailyGlobalLimit, 50);
  for (const bad of ['0', '-1', '2.5', 'lots']) assert.throws(() => loadConfig({ TOKEN_ENCRYPTION_KEY: encryptionKey, ASK_DAILY_GLOBAL_LIMIT: bad }), /ASK_DAILY_GLOBAL_LIMIT/);
});

test('failed questions (429/502/503) hand back both quota slots; answers and refusals keep them', async () => {
  let clock = 0, status = 0;
  const askLimiter = createAskLimiter({ now: () => clock }), askGlobalLimiter = createAskLimiter({ limit: 40, now: () => clock });
  const assistant = { async answer() { if (status) throw Object.assign(new Error('Ask Margin could not answer right now'), { status, expose: true }); return 'ok'; } };
  const f = await fixture({ assistant, askLimiter, askGlobalLimiter });
  const ask = () => f.post('/v1/ask', { question: 'q', context: snapshot });
  try {
    for (status of [502, 503, 429]) for (let i = 0; i < 31; i++) assert.equal((await ask()).status, status, `${status} #${i + 1}`);
    status = 422;
    assert.equal((await ask()).status, 422);
    status = 0;
    for (let i = 0; i < 29; i++) assert.equal((await ask()).status, 200, `answer #${i + 1}`);
    assert.deepEqual(await ask(), { status: 429, data: { error: 'Daily question limit reached' } }, 'the refusal and 29 answers used the 30 slots');
    clock += DAY_MS;
    assert.equal(askLimiter.take('ana'), true);
    assert.equal(askLimiter.size, 1, 'users whose window emptied are pruned');
    askLimiter.release('ana');
    assert.equal(askLimiter.size, 0);
  } finally { await f.close(); }
});

test('context is validated structurally (depth, size, cycles) and hostile nesting is a 400, not a 500', async () => {
  const nest = levels => { let value = 1; for (let i = 0; i < levels; i++) value = { v: value }; return value; }; // `levels` nested objects
  assert.equal(isAskContext(nest(6)), true);
  assert.equal(isAskContext(nest(7)), false);
  assert.equal(isAskContext({ list: Array(399).fill(0) }), true, '400 entries in total');
  assert.equal(isAskContext({ list: Array(400).fill(0) }), false, '401 entries in total');
  const cyclic = { a: {} }; cyclic.a.back = cyclic;
  assert.equal(isAskContext(cyclic), false);
  const shared = { x: 1 };
  assert.equal(isAskContext({ a: shared, b: shared }), true, 'a shared (non-cyclic) object is fine');
  for (const bad of [null, [], 'text', new Date(), new (class Snapshot {})()]) assert.equal(isAskContext(bad), false);
  const assistant = { calls: 0, async answer() { this.calls++; return 'ok'; } };
  const f = await fixture({ assistant });
  try {
    const deep = `{"question":"q","context":{"a":${'['.repeat(15000)}${']'.repeat(15000)}}}`;
    const r = await f.call('/v1/ask', { method: 'POST', body: deep });
    assert.equal(r.status, 400);
    assert.equal((await f.post('/v1/ask', { question: 'q', context: nest(7) })).status, 400);
    assert.equal((await f.post('/v1/ask', { question: 'q', context: { list: Array(401).fill(0) } })).status, 400);
    assert.equal((await f.post('/v1/ask', { question: 'q', context: nest(6) })).status, 200);
    assert.equal(assistant.calls, 1);
  } finally { await f.close(); }
});

// ---- 2. Session revocation ----

test('account deletion ends old sessions while a later sign-in (same second) works', async () => {
  const f = await fixture();
  try {
    const first = await f.signIn('u1');
    assert.deepEqual([claimsOf(first).iat, claimsOf(first).gen], [T, 0]);
    assert.equal((await f.call('/v1/plaid/accounts', { auth: first })).status, 200);
    assert.deepEqual(await f.call('/v1/account', { method: 'DELETE', auth: first }), { status: 200, data: { deleted: true } });
    assert.deepEqual(await f.call('/v1/plaid/accounts', { auth: first }), { status: 401, data: { error: ENDED } });
    assert.equal((await f.call('/v1/plaid/accounts', { auth: f.session('apple:u1', null) })).status, 401, 'a session without gen is ended too');
    const disk = await f.readDisk();
    assert.equal(Object.hasOwn(disk.users, 'apple:u1'), false);
    assert.equal(disk.sessionGenerations['apple:u1'], 1, 'the generation outlives the user record');
    const second = await f.signIn('u1'); // still the same second as the deletion
    const payload = claimsOf(second);
    assert.deepEqual([payload.iat, payload.gen], [T, 1]);
    assert.equal(payload.exp - payload.iat, 30 * 86400);
    assert.equal((await f.call('/v1/plaid/accounts', { auth: second })).status, 200);
    f.clock.s += 10;
    assert.equal((await f.call('/v1/plaid/accounts', { auth: f.session('apple:u1', T + 2) })).status, 401, 'a later iat without gen (another issuer) no longer works once the user has revoked');
  } finally { await f.close(); }
});

test('a revocation in the same second as the sign-in before it still ends that session', async () => {
  const f = await fixture();
  try {
    const a = await f.signIn('s1');
    assert.equal((await f.call('/v1/session', { method: 'DELETE', auth: a })).status, 200);
    const b = await f.signIn('s1'); // same second as the first revocation
    assert.equal((await f.call('/v1/plaid/accounts', { auth: b })).status, 200, 'a sign-in after revocation works');
    assert.equal((await f.call('/v1/session', { method: 'DELETE', auth: b })).status, 200); // and again, same second
    for (const token of [a, b]) assert.deepEqual(await f.call('/v1/plaid/accounts', { auth: token }), { status: 401, data: { error: ENDED } });
    const c = await f.signIn('s1');
    assert.equal(claimsOf(c).gen, 2);
    assert.equal((await f.call('/v1/plaid/accounts', { auth: c })).status, 200);
  } finally { await f.close(); }
});

test('DELETE /v1/session signs the caller out everywhere', async () => {
  const f = await fixture();
  try {
    const phone = await f.signIn('u2'), tablet = await f.signIn('u2'), other = await f.signIn('u3');
    assert.equal((await f.call('/v1/session', { method: 'DELETE', auth: null })).status, 401);
    assert.deepEqual(await f.call('/v1/session', { method: 'DELETE', auth: phone }), { status: 200, data: { signedOut: true } });
    for (const token of [phone, tablet]) assert.deepEqual(await f.call('/v1/plaid/accounts', { auth: token }), { status: 401, data: { error: ENDED } });
    assert.equal((await f.call('/v1/plaid/accounts', { auth: other })).status, 200, 'other users are untouched');
    assert.equal((await f.call('/v1/plaid/accounts', { auth: await f.signIn('u2') })).status, 200);
  } finally { await f.close(); }
});

test('the store migrates old revocations, keeps own-key safety, and only moves generations forward', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'margin-store-')), file = path.join(dir, 'data.json');
  const item = { itemId: 'i', accessToken: 'a', institutionName: 'B' };
  try {
    await fs.writeFile(file, JSON.stringify({ users: { matt: { items: {}, transactions: {} } }, revocations: { ana: T, toString: T } }));
    const store = new FileStore(file, encryptionKey);
    assert.equal(await store.sessionGeneration('matt'), 0);
    assert.equal(await store.sessionGeneration('toString'), 0);
    assert.equal(await store.sessionGeneration('ana'), 1, 'a user revoked under the timestamp scheme starts at generation 1');
    await assert.rejects(store.revokeSessions('__proto__'), { status: 400 });
    assert.equal(await store.revokeSessions('matt'), 1);
    assert.equal(await store.revokeSessions('matt'), 2);
    const disk = JSON.parse(await fs.readFile(file, 'utf8'));
    assert.equal('revocations' in disk, false);
    assert.deepEqual(disk.sessionGenerations, { ana: 1, matt: 2 });
    for (const gen of [undefined, 1, 3, '2']) await assert.rejects(store.saveItem('matt', item, gen), { status: 401, message: ENDED }, String(gen));
    await store.saveItem('matt', item, 2);
    assert.equal(await store.getAccessToken('matt', 'i'), 'a');
    await assert.rejects(store.deleteUser('matt'), { status: 409 }, 'never deletes a user whose Items are still stored');
    assert.equal(await store.getAccessToken('matt', 'i'), 'a');
    assert.equal(await store.sessionGeneration('matt'), 2, 'a refused deletion ends no sessions');
    await store.beginDeletion('matt', 2);
    await assert.rejects(store.saveItem('matt', { ...item, itemId: 'j' }, 2), { status: 409, message: 'Account is being deleted' });
    assert.equal(await store.saveAppleRefreshToken('matt', 'late-refresh'), false, 'a token arriving mid-deletion is queued for revocation');
    assert.deepEqual((await store.pendingAppleRevocations()).map(entry => entry.refreshToken), ['late-refresh']);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});

test('session lifetime is capped at 90 days', async () => {
  assert.throws(() => loadConfig({ TOKEN_ENCRYPTION_KEY: encryptionKey, MARGIN_SESSION_TTL_DAYS: '91' }), /1 to 90/);
  const f = await fixture({ config: { sessionTtlDays: 365 } }); // even if a config object bypasses loadConfig
  try {
    const payload = JSON.parse(Buffer.from((await f.signIn('u4')).split('.')[1], 'base64url'));
    assert.equal(payload.exp - payload.iat, 90 * 86400);
  } finally { await f.close(); }
});

// ---- 3. Apple token exchange and revocation ----

const { privateKey: appleP8, publicKey: appleP8Public } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const p8Pem = appleP8.export({ type: 'pkcs8', format: 'pem' });
const escapedPem = p8Pem.trim().replace(/\n/g, '\\n'); // how a single-line env var delivers it

// Fake appleid.apple.com that checks the client_secret signature and the form on every request.
function appleRest({ fail = {} } = {}) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    assert.equal(options.method, 'POST');
    assert.equal(options.headers['content-type'], 'application/x-www-form-urlencoded');
    const form = Object.fromEntries(new URLSearchParams(options.body));
    const [h, p, s] = form.client_secret.split('.');
    assert.equal(crypto.verify('sha256', Buffer.from(`${h}.${p}`), { key: appleP8Public, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url')), true, 'client_secret is ES256-signed with the .p8 key');
    const header = JSON.parse(Buffer.from(h, 'base64url')), claims = JSON.parse(Buffer.from(p, 'base64url'));
    assert.deepEqual(header, { alg: 'ES256', kid: 'KEY123' });
    assert.deepEqual(claims, { iss: 'TEAM123', iat: T, exp: T + 300, aud: 'https://appleid.apple.com', sub: bundleId });
    assert.equal(form.client_id, bundleId);
    const kind = new URL(url).pathname;
    calls.push({ kind, form });
    if (fail[kind]) return { ok: false, status: 400, json: async () => ({ error: 'invalid_grant', error_description: `secret detail ${form.code || form.token}` }) };
    // The code `code-N` belongs to Apple user `uN`.
    if (kind === '/auth/token') { assert.equal(form.grant_type, 'authorization_code'); return { ok: true, status: 200, json: async () => ({ access_token: 'at', refresh_token: `refresh-for-${form.code}`, id_token: idTokenFor(form.code.replace(/^code-/, 'u')) }) }; }
    assert.equal(kind, '/auth/revoke');
    assert.equal(form.token_type_hint, 'refresh_token');
    return { ok: true, status: 200, json: async () => ({}) };
  };
  return { calls, fetchImpl };
}
const tokenClient = (fetchImpl, overrides = {}) => new AppleTokenClient({ bundleId, teamId: 'TEAM123', keyId: 'KEY123', privateKey: escapedPem, fetchImpl, now: () => T * 1000, ...overrides });

test('AppleTokenClient signs an ES256 client secret and exchanges/revokes with form posts', async () => {
  const rest = appleRest();
  const client = tokenClient(rest.fetchImpl);
  assert.equal(client.configured, true);
  const exchanged = await client.exchange('auth-code');
  assert.deepEqual([exchanged.refreshToken, idTokenSubject(exchanged.idToken)], ['refresh-for-auth-code', 'auth-code']);
  await client.revoke('refresh-for-auth-code');
  assert.deepEqual(rest.calls.map(c => [c.kind, c.form.code ?? c.form.token]), [['/auth/token', 'auth-code'], ['/auth/revoke', 'refresh-for-auth-code']]);
  for (const missing of ['teamId', 'keyId', 'privateKey', 'bundleId']) assert.equal(tokenClient(rest.fetchImpl, { [missing]: '' }).configured, false, missing);
  const failing = tokenClient(appleRest({ fail: { '/auth/token': true } }).fetchImpl);
  await assert.rejects(failing.exchange('auth-code'), error => error.status === 502 && error.message === 'Apple /auth/token failed: HTTP 400 invalid_grant');
});

test('sign-in stores the Apple refresh token encrypted and account deletion revokes it', async () => {
  const rest = appleRest();
  const f = await fixture({ appleTokens: tokenClient(rest.fetchImpl) });
  try {
    const token = await f.signIn('u5', { authorizationCode: 'code-5' });
    const disk = JSON.stringify(await f.readDisk());
    assert.equal(disk.includes('refresh-for-code-5'), false, 'refresh token is encrypted at rest');
    assert.equal(await f.store.getAppleRefreshToken('apple:u5'), 'refresh-for-code-5');
    assert.equal((await f.call('/v1/account', { method: 'DELETE', auth: token })).status, 200);
    assert.deepEqual(rest.calls.map(c => [c.kind, c.form.code ?? c.form.token]), [['/auth/token', 'code-5'], ['/auth/revoke', 'refresh-for-code-5']]);
    assert.equal(Object.hasOwn((await f.readDisk()).users, 'apple:u5'), false);
    for (const authorizationCode of [42, 'c'.repeat(1025), { code: 'x' }]) assert.equal((await f.post('/v1/auth/apple', { identityToken: 'u5', nonce: 'n', authorizationCode }, { auth: null })).status, 400);
  } finally { await f.close(); }
});

test('Apple exchange and revoke failures never block sign-in or deletion, and logs carry no secrets', async () => {
  const logs = [];
  const rest = appleRest({ fail: { '/auth/token': true, '/auth/revoke': true } });
  const f = await fixture({ appleTokens: tokenClient(rest.fetchImpl) });
  try {
    await quietly(async () => {
      const token = await f.signIn('u6', { authorizationCode: 'secret-code-6' });
      assert.equal(await f.store.getAppleRefreshToken('apple:u6'), null);
      await f.store.saveAppleRefreshToken('apple:u6', 'secret-refresh-6');
      assert.equal((await f.call('/v1/account', { method: 'DELETE', auth: token })).status, 200);
    }, logs);
    assert.equal(rest.calls.length, 2);
    assert.equal(logs.length, 2);
    for (const line of logs) assert.equal(/secret|TEAM123|KEY123|PRIVATE/.test(line), false, line);
  } finally { await f.close(); }
  const skipped = await fixture(); // no appleTokens: the code is accepted and ignored
  try { assert.equal((await skipped.post('/v1/auth/apple', { identityToken: 'u7', nonce: 'n', authorizationCode: 'code' }, { auth: null })).status, 200); } finally { await skipped.close(); }
});

test('the Apple refresh token is stored only when the code\'s id_token names the signed-in user', async () => {
  const logs = [];
  const f = await fixture({ appleTokens: tokenClient(appleRest().fetchImpl) });
  try {
    await f.signIn('u9', { authorizationCode: 'code-9' });
    assert.equal(await f.store.getAppleRefreshToken('apple:u9'), 'refresh-for-code-9');
    await quietly(() => f.signIn('u10', { authorizationCode: 'code-9' }), logs); // someone else's code
    assert.equal(await f.store.getAppleRefreshToken('apple:u10'), null);
    assert.equal(await f.store.getAppleRefreshToken('apple:u9'), 'refresh-for-code-9');
    assert.deepEqual(logs, ['Apple authorization code does not belong to the signed-in user; refresh token not stored']);
  } finally { await f.close(); }
  assert.equal(idTokenSubject('not-a-jwt'), null);
  assert.equal(idTokenSubject(null), null);
});

test('a failed Apple revocation is queued at deletion and retried until it succeeds or expires', async () => {
  const logs = [], attempts = [];
  let failing = true;
  const appleTokens = { configured: true, async revoke(token) { attempts.push(token); if (failing) throw Object.assign(new Error('Apple /auth/revoke failed: HTTP 503'), { status: 502 }); } };
  const f = await fixture({ appleTokens });
  const retry = (ms = T * 1000) => retryPendingAppleRevocations({ store: f.store, appleTokens, now: () => ms });
  try {
    await quietly(async () => {
      for (const sub of ['q1', 'q2']) {
        const token = await f.signIn(sub);
        await f.store.saveAppleRefreshToken(`apple:${sub}`, `refresh-${sub}`);
        assert.equal((await f.call('/v1/account', { method: 'DELETE', auth: token })).status, 200, 'deletion still completes');
      }
      const disk = await f.readDisk();
      assert.deepEqual(disk.pendingAppleRevocations.map(entry => entry.queuedAt), [new Date(T * 1000).toISOString(), new Date(T * 1000).toISOString()]);
      assert.equal(JSON.stringify(disk).includes('refresh-q'), false, 'queued tokens stay encrypted');
      assert.deepEqual(Object.keys(disk.users), []);
      assert.deepEqual(await retry(), { revoked: 0, kept: 2, expired: 0 });
      assert.equal((await f.readDisk()).pendingAppleRevocations.length, 2, 'kept while Apple keeps failing');
      failing = false;
      attempts.length = 0;
      assert.deepEqual(await retry(), { revoked: 2, kept: 0, expired: 0 });
      assert.deepEqual(attempts, ['refresh-q1', 'refresh-q2']);
      assert.deepEqual((await f.readDisk()).pendingAppleRevocations, []);
      failing = true;
      const token = await f.signIn('q3');
      await f.store.saveAppleRefreshToken('apple:q3', 'refresh-q3');
      assert.equal((await f.call('/v1/account', { method: 'DELETE', auth: token })).status, 200);
      attempts.length = 0;
      assert.deepEqual(await retry(T * 1000 + 31 * DAY_MS), { revoked: 0, kept: 0, expired: 1 });
      assert.deepEqual(attempts, [], 'an expired entry is dropped without another attempt');
      assert.deepEqual((await f.readDisk()).pendingAppleRevocations, []);
    }, logs);
    assert.ok(logs.some(line => line.includes('older than 30 days')));
    for (const line of logs) assert.equal(line.includes('refresh-q'), false, line);
  } finally { await f.close(); }
});

test('config requires Apple credentials together and as a PEM key, accepting literal \\n', () => {
  const base = { TOKEN_ENCRYPTION_KEY: encryptionKey };
  const config = loadConfig({ ...base, APPLE_TEAM_ID: 'TEAM123', APPLE_KEY_ID: 'KEY123', APPLE_PRIVATE_KEY: escapedPem });
  assert.equal(config.applePrivateKey, p8Pem.trim());
  assert.throws(() => loadConfig({ ...base, APPLE_TEAM_ID: 'TEAM123' }), /set together/);
  assert.throws(() => loadConfig({ ...base, APPLE_TEAM_ID: 'TEAM123', APPLE_KEY_ID: 'KEY123', APPLE_PRIVATE_KEY: 'not a key' }), /APPLE_PRIVATE_KEY/);
});

test('config rejects an APPLE_PRIVATE_KEY that is not a P-256 EC key', () => {
  const base = { TOKEN_ENCRYPTION_KEY: encryptionKey, APPLE_TEAM_ID: 'TEAM123', APPLE_KEY_ID: 'KEY123' };
  for (const [type, options] of [['rsa', { modulusLength: 2048 }], ['ec', { namedCurve: 'P-384' }], ['ed25519', undefined]]) {
    const pem = crypto.generateKeyPairSync(type, options).privateKey.export({ type: 'pkcs8', format: 'pem' });
    assert.throws(() => loadConfig({ ...base, APPLE_PRIVATE_KEY: pem }), /APPLE_PRIVATE_KEY must be a P-256/, type);
  }
  assert.equal(loadConfig({ ...base, APPLE_PRIVATE_KEY: p8Pem }).applePrivateKey, p8Pem);
});

// ---- 4. JWKS refetch amplification ----

const rsa = (() => { const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }); return { privateKey, jwk: { ...publicKey.export({ format: 'jwk' }), kid: 'key-a', alg: 'RS256', use: 'sig' } }; })();
let nonceCounter = 0;
function identity({ kid = 'key-a', nowS, claims = {} } = {}) {
  const nonce = `nonce-${++nonceCounter}`;
  const h = Buffer.from(JSON.stringify({ alg: 'RS256', kid })).toString('base64url');
  const p = Buffer.from(JSON.stringify({ iss: 'https://appleid.apple.com', aud: bundleId, sub: '001.abc.0042', iat: nowS, exp: nowS + 600, nonce: sha256Hex(nonce), ...claims })).toString('base64url');
  return { token: `${h}.${p}.${crypto.sign('RSA-SHA256', Buffer.from(`${h}.${p}`), rsa.privateKey).toString('base64url')}`, nonce };
}
function jwks() { const f = async () => { f.calls++; await new Promise(resolve => setImmediate(resolve)); if (f.down) throw new Error('offline'); return { ok: true, json: async () => ({ keys: [rsa.jwk] }) }; }; f.calls = 0; f.down = false; return f; }
const verifierAt = clock => { const fetchImpl = jwks(); return { fetchImpl, verifier: new AppleIdentityVerifier({ bundleId, fetchImpl, now: () => clock.ms }) }; };
const verifyAll = (verifier, tokens) => Promise.allSettled(tokens.map(({ token, nonce }) => verifier.verify(token, nonce)));

test('concurrent forged-kid tokens share one JWKS fetch, cold or warm', async () => {
  const clock = { ms: T * 1000 }, { fetchImpl, verifier } = verifierAt(clock);
  const forged = () => Array.from({ length: 50 }, () => identity({ kid: `forged-${crypto.randomUUID()}`, nowS: clock.ms / 1000 }));
  let results = await verifyAll(verifier, forged());
  assert.equal(fetchImpl.calls, 1, 'cold cache: one fetch');
  assert.ok(results.every(r => r.status === 'rejected' && r.reason.status === 401));
  clock.ms += 2 * 60 * 1000;
  results = await verifyAll(verifier, forged());
  assert.equal(fetchImpl.calls, 2, 'warm cache: one refetch for 50 unknown kids');
  assert.ok(results.every(r => r.status === 'rejected' && r.reason.status === 401));
});

test('a failed refetch is throttled and stale keys keep verifying while Apple is down', async () => {
  const clock = { ms: T * 1000 }, { fetchImpl, verifier } = verifierAt(clock);
  const nowS = () => clock.ms / 1000;
  const check = async ({ token, nonce }) => verifier.verify(token, nonce);
  await check(identity({ nowS: nowS() }));
  assert.equal(fetchImpl.calls, 1);
  clock.ms += 2 * 60 * 1000; fetchImpl.down = true;
  await assert.rejects(check(identity({ kid: 'forged-1', nowS: nowS() })), { status: 401 });
  assert.equal(fetchImpl.calls, 2, 'the unknown kid triggered one (failing) refetch');
  clock.ms += 30 * 1000;
  await assert.rejects(check(identity({ kid: 'forged-2', nowS: nowS() })), { status: 401 });
  assert.equal(fetchImpl.calls, 2, 'no new fetch within a minute of a failed attempt');
  clock.ms += 61 * 60 * 1000; // the cache is now past its hour
  assert.equal((await check(identity({ nowS: nowS() }))).sub, '001.abc.0042', 'stale keys still verify a valid token');
  assert.equal(fetchImpl.calls, 3);
  assert.equal((await check(identity({ nowS: nowS() }))).sub, '001.abc.0042');
  assert.equal(fetchImpl.calls, 3, 'stale-cache refetches are throttled too');
  const cold = verifierAt(clock); cold.fetchImpl.down = true;
  await assert.rejects(cold.verifier.verify(identity({ nowS: nowS() }).token, 'x'), { status: 503 });
  await assert.rejects(cold.verifier.verify(identity({ nowS: nowS() }).token, 'x'), { status: 503 });
  assert.equal(cold.fetchImpl.calls, 1, 'with nothing cached, a failure is retried at most every few seconds');
});

// ---- 5. Delete-vs-link race ----

test('a link that finishes after account deletion is refused and removed at Plaid', async () => {
  let release, exchanged;
  const gate = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { exchanged = resolve; });
  const plaid = new FakePlaid({ async exchange() { exchanged(); await gate; return { access_token: 'access-late', item_id: 'item-late' }; } });
  const f = await fixture({ plaid });
  try {
    const token = await f.signIn('u8');
    const linking = f.post('/v1/plaid/exchange', { publicToken: 'late' }, { auth: token });
    await started;
    assert.deepEqual(await f.call('/v1/account', { method: 'DELETE', auth: token }), { status: 200, data: { deleted: true } });
    release();
    assert.deepEqual(await linking, { status: 401, data: { error: ENDED } });
    assert.deepEqual(plaid.removedTokens, ['access-late']);
    assert.equal(Object.hasOwn((await f.readDisk()).users, 'apple:u8'), false, 'no orphaned Item was stored');
  } finally { await f.close(); }
});

test('an Item linked after the Plaid sweep but before deletion finishes is refused and removed at Plaid', async () => {
  let midDeletion = async () => {}, late;
  const plaid = new FakePlaid();
  const appleTokens = { configured: true, async revoke() { await midDeletion(); } };
  const f = await fixture({ plaid, appleTokens });
  try {
    const token = await f.signIn('d1');
    assert.equal((await f.post('/v1/plaid/exchange', { publicToken: 'early' }, { auth: token })).status, 201);
    await f.store.saveAppleRefreshToken('apple:d1', 'refresh-d1');
    // Runs during step c (Apple revocation): after every Item was removed, before the final atomic step.
    midDeletion = async () => { late = await f.post('/v1/plaid/exchange', { publicToken: 'late' }, { auth: token }); };
    assert.deepEqual(await quietly(() => f.call('/v1/account', { method: 'DELETE', auth: token })), { status: 200, data: { deleted: true } });
    assert.deepEqual(late, { status: 409, data: { error: 'Account is being deleted' } });
    assert.deepEqual(plaid.removedTokens, ['access-early', 'access-late'], 'the late Item was removed at Plaid, not dropped');
    assert.equal(Object.hasOwn((await f.readDisk()).users, 'apple:d1'), false);
  } finally { await f.close(); }
});

test('a Plaid failure mid-deletion leaves the session usable and the same DELETE can be retried', async () => {
  let failing = true;
  const plaid = new FakePlaid({ async remove(token) { if (failing) throw plaidError('INTERNAL_SERVER_ERROR'); this.removedTokens.push(token); return {}; } });
  const appleTokens = { configured: true, revoked: [], async revoke(token) { this.revoked.push(token); } };
  const f = await fixture({ plaid, appleTokens });
  try {
    const token = await f.signIn('d2');
    assert.equal((await f.post('/v1/plaid/exchange', { publicToken: 'a' }, { auth: token })).status, 201);
    await f.store.saveAppleRefreshToken('apple:d2', 'refresh-d2');
    assert.equal((await f.call('/v1/account', { method: 'DELETE', auth: token })).status, 502);
    const after = await f.call('/v1/plaid/accounts', { auth: token });
    assert.equal(after.status, 200, 'the session survives a failed deletion');
    assert.deepEqual(after.data.connections.map(c => c.itemId), ['item-a']);
    assert.deepEqual(appleTokens.revoked, [], 'Apple is only revoked once every Item is gone');
    failing = false;
    assert.deepEqual(await f.call('/v1/account', { method: 'DELETE', auth: token }), { status: 200, data: { deleted: true } });
    assert.deepEqual([plaid.removedTokens, appleTokens.revoked], [['access-a'], ['refresh-d2']]);
    assert.deepEqual(await f.call('/v1/plaid/accounts', { auth: token }), { status: 401, data: { error: ENDED } });
  } finally { await f.close(); }
});

// ---- 6. Identity-token replay and iat window ----

test('an identity token is single use and its iat must be recent', async () => {
  const clock = { ms: T * 1000 }, { verifier } = verifierAt(clock), nowS = T;
  const once = identity({ nowS });
  assert.equal((await verifier.verify(once.token, once.nonce)).sub, '001.abc.0042');
  await assert.rejects(verifier.verify(once.token, once.nonce), { status: 401 });
  const future = identity({ nowS, claims: { iat: nowS + 11 * 60 } }), nearFuture = identity({ nowS, claims: { iat: nowS + 9 * 60 } });
  const old = identity({ nowS, claims: { iat: nowS - 86400 - 1 } }), missing = identity({ nowS, claims: { iat: undefined } });
  for (const bad of [future, old, missing]) await assert.rejects(verifier.verify(bad.token, bad.nonce), { status: 401 });
  assert.equal((await verifier.verify(nearFuture.token, nearFuture.nonce)).sub, '001.abc.0042');
  clock.ms += 11 * 60 * 1000; // past every token's exp: remembered nonces are pruned
  const fresh = identity({ nowS: clock.ms / 1000 });
  await verifier.verify(fresh.token, fresh.nonce);
  assert.equal(verifier.usedNonces.size, 1);
});

// ---- 7. Error codes ----

test('only Plaid-style codes reach clients, and never system codes on 5xx', async () => {
  let failure = null;
  const store = s => Object.assign(Object.create(s), { async getUser(userId) { if (failure) throw failure; return s.getUser(userId); } });
  const f = await fixture({ store });
  try {
    for (const code of ['ENOTDIR', 23, 'EACCES']) {
      failure = Object.assign(new Error('ENOTDIR: not a directory, open /srv/secret/data.json'), { code });
      assert.deepEqual(await f.call('/v1/plaid/accounts'), { status: 500, data: { error: 'Bank service temporarily unavailable' } }, String(code));
    }
    failure = Object.assign(new Error('Upstream'), { status: 502, code: 'INTERNAL_SERVER_ERROR' }); // not marked as Plaid's
    assert.deepEqual(await f.call('/v1/plaid/accounts'), { status: 502, data: { error: 'Bank service temporarily unavailable' } });
    failure = Object.assign(new Error('Conflict'), { status: 409, code: 'lower-case code' });
    assert.deepEqual(await f.call('/v1/plaid/accounts'), { status: 409, data: { error: 'Conflict' } });
    failure = plaidError('ITEM_LOGIN_REQUIRED', 409);
    assert.equal((await f.call('/v1/plaid/accounts')).data.code, 'ITEM_LOGIN_REQUIRED');
  } finally { await f.close(); }
  const plaid = new PlaidClient({ plaidClientId: 'x', plaidSecret: 'y', plaidEnv: 'sandbox' }, async () => ({ ok: false, json: async () => ({ error_code: 'INVALID_FIELD', error_message: 'detail' }) }));
  const g = await fixture({ plaid });
  try { assert.deepEqual(await g.post('/v1/plaid/link-token', {}), { status: 502, data: { error: 'Bank service temporarily unavailable', code: 'INVALID_FIELD' } }); } finally { await g.close(); }
});

// ---- 8. Production config ----

test('production requires APPLE_BUNDLE_ID', () => {
  const env = { NODE_ENV: 'production', PLAID_ENV: 'production', MARGIN_JWT_SECRET: secret, MARGIN_JWT_ISSUER: 'iss', MARGIN_JWT_AUDIENCE: 'aud', PLAID_CLIENT_ID: 'c', PLAID_SECRET: 's', TOKEN_ENCRYPTION_KEY: encryptionKey };
  assert.throws(() => loadConfig(env), /APPLE_BUNDLE_ID is required in production/);
  assert.equal(loadConfig({ ...env, APPLE_BUNDLE_ID: bundleId }).appleBundleId, bundleId);
});
