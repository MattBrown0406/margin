import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { once } from 'node:events';
import { createApp } from '../src/app.js';
import { FileStore } from '../src/store.js';
import { signTestToken } from '../src/auth.js';
import { loadConfig } from '../src/config.js';
import { AppleIdentityVerifier, sha256Hex } from '../src/apple.js';
import { createAssistant, createAskLimiter, readAnswer, mapSdkError, SYSTEM_PROMPT } from '../src/assistant.js';

const secret = 'test-jwt-secret-that-is-at-least-thirty-two-characters';
const encryptionKey = '11'.repeat(32);
const bundleId = 'com.margin.app';
const rawNonce = 'raw-nonce-from-the-phone';
const plaidError = (code, status = 502) => Object.assign(new Error(code), { code, status });

// Real RSA keys standing in for Apple's signing keys.
const appleKey = kid => { const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }); return { kid, privateKey, jwk: { ...publicKey.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' } }; };
const keyA = appleKey('key-a'), keyB = appleKey('key-b'), rogue = appleKey('key-a');
const nowS = () => Math.floor(Date.now() / 1000);
const appleClaims = (overrides = {}) => ({ iss: 'https://appleid.apple.com', aud: bundleId, sub: '001234.abcdef0123456789.0042', iat: nowS(), exp: nowS() + 600, nonce: sha256Hex(rawNonce), ...overrides });
function appleToken(claims = appleClaims(), { key = keyA, kid = key.kid, alg = 'RS256' } = {}) {
  const h = Buffer.from(JSON.stringify({ alg, kid })).toString('base64url'), p = Buffer.from(JSON.stringify(claims)).toString('base64url');
  return `${h}.${p}.${crypto.sign('RSA-SHA256', Buffer.from(`${h}.${p}`), key.privateKey).toString('base64url')}`;
}
// JWKS endpoint whose key set the test can rotate; counts fetches.
function jwks(keys = [keyA]) { const f = async url => { assert.equal(url, 'https://appleid.apple.com/auth/keys'); f.calls++; if (f.down) throw new Error('offline'); return { ok: true, json: async () => ({ keys: f.keys.map(k => k.jwk) }) }; }; f.calls = 0; f.keys = keys; f.down = false; return f; }

class FakePlaid {
  constructor(overrides = {}) { this.removedTokens = []; Object.assign(this, overrides); }
  async createLinkToken(user) { return { link_token: `link-${user}`, expiration: '2030-01-01T00:00:00Z' }; }
  async exchange(token) { return { access_token: `access-${token}`, item_id: `item-${token}` }; }
  async accounts(token) { return { accounts: [{ account_id: `acct-${token}`, name: 'Checking', type: 'depository', subtype: 'checking', mask: '0001', balances: { current: 100 } }] }; }
  async syncAll() { return { cursor: 'c', added: [], modified: [], removed: [] }; }
  async remove(token) { this.removedTokens.push(token); return {}; }
}

async function fixture({ plaid = new FakePlaid(), apple, assistant, askLimiter, config: extra = {} } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'margin-feat-')), file = path.join(dir, 'data.json');
  const config = { plaidEnv: 'sandbox', plaidClientId: 'client', plaidSecret: 'secret', jwtSecret: secret, jwtIssuer: 'margin-test', jwtAudience: 'margin-bank-api', appleBundleId: bundleId, sessionTtlDays: 30, ...extra };
  const server = createApp({ config, plaid, store: new FileStore(file, encryptionKey), apple, assistant, ...(askLimiter ? { askLimiter } : {}) });
  server.listen(0); await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const token = signTestToken({ sub: 'matt', iss: 'margin-test', aud: 'margin-bank-api', exp: nowS() + 300 }, secret);
  const call = async (url, { auth = token, ...options } = {}) => { const r = await fetch(base + url, { ...options, headers: { 'content-type': 'application/json', ...(auth ? { authorization: `Bearer ${auth}` } : {}) } }); return { status: r.status, data: await r.json() }; };
  const post = (url, payload, options = {}) => call(url, { method: 'POST', body: JSON.stringify(payload), ...options });
  const link = publicToken => post('/v1/plaid/exchange', { publicToken });
  const readDisk = async () => JSON.parse(await fs.readFile(file, 'utf8'));
  return { call, post, link, readDisk, close: async () => { server.close(); await once(server, 'close'); await fs.rm(dir, { recursive: true, force: true }); } };
}

// ---- Sign in with Apple ----

test('a verified Apple token yields a Margin session that authenticates bank routes', async () => {
  const apple = new AppleIdentityVerifier({ bundleId, fetchImpl: jwks() });
  const f = await fixture({ apple });
  try {
    const { status, data } = await f.post('/v1/auth/apple', { identityToken: appleToken(), nonce: rawNonce }, { auth: null });
    assert.equal(status, 200);
    assert.equal(data.userId, 'apple:001234.abcdef0123456789.0042');
    assert.ok(Math.abs(Date.parse(data.expiresAt) - (Date.now() + 30 * 86400000)) < 5000);
    const payload = JSON.parse(Buffer.from(data.sessionToken.split('.')[1], 'base64url').toString());
    assert.deepEqual([payload.sub, payload.iss, payload.aud], [data.userId, 'margin-test', 'margin-bank-api']);
    const accounts = await f.call('/v1/plaid/accounts', { auth: data.sessionToken });
    assert.equal(accounts.status, 200);
    assert.deepEqual(accounts.data.connections, []);
  } finally { await f.close(); }
});

test('session omits iss/aud when not configured and honours the TTL', async () => {
  const f = await fixture({ apple: new AppleIdentityVerifier({ bundleId, fetchImpl: jwks() }), config: { jwtIssuer: '', jwtAudience: '', sessionTtlDays: 7 } });
  try {
    const { data } = await f.post('/v1/auth/apple', { identityToken: appleToken(), nonce: rawNonce }, { auth: null });
    const payload = JSON.parse(Buffer.from(data.sessionToken.split('.')[1], 'base64url').toString());
    assert.equal('iss' in payload || 'aud' in payload, false);
    assert.equal(payload.exp - payload.iat, 7 * 86400);
    assert.equal((await f.call('/v1/plaid/accounts', { auth: data.sessionToken })).status, 200);
  } finally { await f.close(); }
});

test('Apple tokens with bad claims, nonce, signature, or alg are rejected with 401', async () => {
  const f = await fixture({ apple: new AppleIdentityVerifier({ bundleId, fetchImpl: jwks() }) });
  try {
    const { nonce: _omit, ...noNonce } = appleClaims();
    const cases = {
      'wrong aud': appleToken(appleClaims({ aud: 'com.someone.else' })),
      'wrong iss': appleToken(appleClaims({ iss: 'https://evil.example' })),
      expired: appleToken(appleClaims({ exp: nowS() - 1 })),
      'missing nonce': appleToken(noNonce),
      'wrong nonce': appleToken(appleClaims({ nonce: sha256Hex('other-nonce') })),
      'raw (unhashed) nonce': appleToken(appleClaims({ nonce: rawNonce })),
      'bad signature': appleToken(appleClaims(), { key: rogue }),
      'HS256 alg': appleToken(appleClaims(), { alg: 'HS256' }),
      'bad sub': appleToken(appleClaims({ sub: 'has spaces' })),
      'garbage': 'not.a.jwt',
    };
    for (const [name, identityToken] of Object.entries(cases)) {
      const { status, data } = await f.post('/v1/auth/apple', { identityToken, nonce: rawNonce }, { auth: null });
      assert.equal(status, 401, name);
      assert.equal(data.error, 'Apple sign-in could not be verified', name);
    }
    assert.equal((await f.post('/v1/auth/apple', { identityToken: appleToken(appleClaims({ aud: ['x', bundleId] })), nonce: rawNonce }, { auth: null })).status, 200, 'array aud');
  } finally { await f.close(); }
});

test('Apple sign-in rejects malformed bodies and reports 503 when unconfigured or Apple is unreachable', async () => {
  const fetchImpl = jwks();
  let f = await fixture({ apple: new AppleIdentityVerifier({ bundleId, fetchImpl }) });
  try {
    assert.equal((await f.post('/v1/auth/apple', { identityToken: appleToken() }, { auth: null })).status, 400);
    assert.equal((await f.post('/v1/auth/apple', { identityToken: 'x'.repeat(4097), nonce: rawNonce }, { auth: null })).status, 400);
    assert.equal((await f.post('/v1/auth/apple', { identityToken: appleToken(), nonce: 'n'.repeat(129) }, { auth: null })).status, 400);
    fetchImpl.down = true;
    assert.equal((await f.post('/v1/auth/apple', { identityToken: appleToken(), nonce: rawNonce }, { auth: null })).status, 503);
  } finally { await f.close(); }
  for (const options of [{}, { apple: new AppleIdentityVerifier({ bundleId, fetchImpl: jwks() }), config: { appleBundleId: '' } }, { apple: new AppleIdentityVerifier({ bundleId, fetchImpl: jwks() }), config: { jwtSecret: 'short' } }]) {
    f = await fixture(options);
    try { const r = await f.post('/v1/auth/apple', { identityToken: appleToken(), nonce: rawNonce }, { auth: null }); assert.equal(r.status, 503); assert.equal(r.data.error, 'Sign in with Apple is not configured'); } finally { await f.close(); }
  }
});

test('Apple keys are cached for an hour and refetched once for an unknown kid', async () => {
  let clock = Date.now();
  const fetchImpl = jwks([keyA]), verifier = new AppleIdentityVerifier({ bundleId, fetchImpl, now: () => clock });
  // Identity tokens are single use, so each verification signs a fresh nonce.
  const fresh = (nonce, claims = {}, options) => verifier.verify(appleToken(appleClaims({ nonce: sha256Hex(nonce), ...claims }), options), nonce);
  await fresh('n1');
  await fresh('n2');
  assert.equal(fetchImpl.calls, 1);
  clock += 2 * 60 * 1000; fetchImpl.keys = [keyA, keyB]; // Apple rotates in key-b
  assert.equal((await fresh('n3', {}, { key: keyB })).sub, appleClaims().sub);
  assert.equal(fetchImpl.calls, 2);
  await assert.rejects(fresh('n4', {}, { key: keyB, kid: 'unknown' }), { status: 401 });
  assert.equal(fetchImpl.calls, 2, 'unknown kids cannot force back-to-back refetches');
  clock += 61 * 60 * 1000;
  await fresh('n5', { exp: Math.floor(clock / 1000) + 600 });
  assert.equal(fetchImpl.calls, 3, 'cache expires after an hour');
});

// ---- Account deletion ----

test('account deletion revokes every Item, tolerates ITEM_NOT_FOUND, and wipes the user', async () => {
  const plaid = new FakePlaid({ async remove(token) { this.removedTokens.push(token); if (token === 'access-b') throw plaidError('ITEM_NOT_FOUND', 400); return {}; } });
  const f = await fixture({ plaid });
  try {
    await f.link('a'); await f.link('b');
    const { status, data } = await f.call('/v1/account', { method: 'DELETE' });
    assert.equal(status, 200); assert.deepEqual(data, { deleted: true });
    assert.deepEqual(plaid.removedTokens.sort(), ['access-a', 'access-b']);
    assert.equal(Object.hasOwn((await f.readDisk()).users, 'matt'), false);
    assert.equal((await f.call('/v1/plaid/accounts')).status, 401, 'the deleted account\'s session is revoked');
  } finally { await f.close(); }
});

test('account deletion stops on other Plaid errors, keeps remaining data, and can be retried', async () => {
  let failing = true;
  const plaid = new FakePlaid({ async remove(token) { if (token === 'access-b' && failing) throw plaidError('INTERNAL_SERVER_ERROR'); this.removedTokens.push(token); return {}; } });
  const f = await fixture({ plaid });
  try {
    await f.link('a'); await f.link('b');
    assert.equal((await f.call('/v1/account', { method: 'DELETE' })).status, 502);
    const left = (await f.call('/v1/plaid/accounts')).data.connections.map(c => c.itemId);
    assert.deepEqual(left, ['item-b']);
    assert.equal(Object.hasOwn((await f.readDisk()).users, 'matt'), true);
    failing = false;
    assert.equal((await f.call('/v1/account', { method: 'DELETE' })).status, 200);
    assert.equal(Object.hasOwn((await f.readDisk()).users, 'matt'), false);
  } finally { await f.close(); }
});

test('deleting an account with no data succeeds and requires auth', async () => {
  const f = await fixture();
  try {
    assert.deepEqual(await f.call('/v1/account', { method: 'DELETE' }), { status: 200, data: { deleted: true } });
    assert.equal((await f.call('/v1/account', { method: 'DELETE', auth: null })).status, 401);
  } finally { await f.close(); }
});

// ---- Ask Margin ----

const snapshot = { verdict: 'fitsNextMonth', price: 480, peaceNumber: 3000, flexible: [{ name: 'Dining', remaining: 120 }] };

test('/v1/ask returns 503 without an assistant and validates input', async () => {
  let f = await fixture();
  try { const r = await f.post('/v1/ask', { question: 'Can I afford it?', context: snapshot }); assert.equal(r.status, 503); assert.equal(r.data.error, "Ask Margin isn't configured"); } finally { await f.close(); }
  const assistant = { calls: 0, async answer() { this.calls++; return 'ok'; } };
  f = await fixture({ assistant });
  try {
    const bad = [{ context: snapshot }, { question: '   ', context: snapshot }, { question: 'x'.repeat(501), context: snapshot }, { question: 7, context: snapshot }, { question: 'Can I?' }, { question: 'Can I?', context: [1] }, { question: 'Can I?', context: 'text' }, { question: 'Can I?', context: { blob: 'x'.repeat(8000) } }];
    for (const payload of bad) assert.equal((await f.post('/v1/ask', payload)).status, 400, JSON.stringify(payload).slice(0, 60));
    assert.equal(assistant.calls, 0);
    assert.equal((await f.post('/v1/ask', { question: 'Can I?', context: snapshot }, { auth: null })).status, 401);
  } finally { await f.close(); }
});

test('/v1/ask answers with the assistant and surfaces refusals as 422', async () => {
  const seen = [];
  let refuse = false;
  const assistant = { async answer(input) { seen.push(input); if (refuse) throw Object.assign(new Error("Margin can't help with that question."), { status: 422 }); return 'It fits next month if Dining drops by $40.'; } };
  const f = await fixture({ assistant });
  try {
    const { status, data } = await f.post('/v1/ask', { question: '  Can I buy the camera?  ', context: snapshot });
    assert.equal(status, 200); assert.deepEqual(data, { answer: 'It fits next month if Dining drops by $40.' });
    assert.deepEqual(seen[0], { question: 'Can I buy the camera?', context: snapshot });
    refuse = true;
    const refused = await f.post('/v1/ask', { question: 'Something off-limits', context: snapshot });
    assert.equal(refused.status, 422); assert.equal(refused.data.error, "Margin can't help with that question.");
  } finally { await f.close(); }
});

test('/v1/ask allows 30 questions per rolling day per user', async () => {
  let clock = 0;
  const f = await fixture({ assistant: { async answer() { return 'ok'; } }, askLimiter: createAskLimiter({ now: () => clock }) });
  try {
    for (let i = 0; i < 30; i++) { assert.equal((await f.post('/v1/ask', { question: `q${i}`, context: snapshot })).status, 200); clock += 1000; }
    const limited = await f.post('/v1/ask', { question: 'q31', context: snapshot });
    assert.equal(limited.status, 429); assert.equal(limited.data.error, 'Daily question limit reached');
    assert.equal((await f.post('/v1/ask', { question: 'bad' })).status, 400, 'invalid requests are rejected before the limiter');
    clock = 24 * 60 * 60 * 1000; // the first ask has rolled out of the window
    assert.equal((await f.post('/v1/ask', { question: 'q32', context: snapshot })).status, 200);
    assert.equal((await f.post('/v1/ask', { question: 'q33', context: snapshot })).status, 429);
  } finally { await f.close(); }
});

test('readAnswer checks refusal before content and joins only text blocks', () => {
  assert.throws(() => readAnswer({ stop_reason: 'refusal', content: [{ type: 'text', text: 'partial' }] }), { status: 422, message: "Margin can't help with that question." });
  assert.equal(readAnswer({ stop_reason: 'end_turn', content: [{ type: 'thinking', thinking: '' }, { type: 'fallback', from: {}, to: {} }, { type: 'text', text: 'Yes, ' }, { type: 'text', text: 'next month.' }] }), 'Yes, next month.');
  assert.throws(() => readAnswer({ stop_reason: 'end_turn', content: [{ type: 'thinking', thinking: '' }] }), { status: 502 });
  assert.throws(() => readAnswer({ stop_reason: 'end_turn', content: [{ type: 'text', text: '  ' }] }), { status: 502 });
});

test('createAssistant is off without a key and sends the documented request through the SDK', async () => {
  assert.equal(createAssistant({ anthropicApiKey: '' }), null);
  class APIError extends Error {}
  class RateLimitError extends APIError {}
  class AuthenticationError extends APIError {}
  const requests = [];
  let outcome = () => ({ stop_reason: 'end_turn', content: [{ type: 'text', text: 'Fits in November.' }] });
  const constructed = [];
  class Anthropic { constructor(options) { this.options = options; constructed.push(options); this.beta = { messages: { create: async params => { requests.push(params); return outcome(); } } }; } }
  Object.assign(Anthropic, { APIError, RateLimitError, AuthenticationError });
  let loads = 0;
  const assistant = createAssistant({ anthropicApiKey: 'sk-test', anthropicModel: 'claude-opus-5-5' }, { loadSdk: async () => { loads++; return { default: Anthropic }; } });
  assert.equal(await assistant.answer({ question: 'Can I?', context: snapshot }), 'Fits in November.');
  const sent = requests[0];
  assert.deepEqual({ ...sent, system: undefined, messages: undefined }, { model: 'claude-opus-5-5', max_tokens: 3000, betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default', output_config: { effort: 'low' }, system: undefined, messages: undefined });
  assert.deepEqual(constructed, [{ apiKey: 'sk-test', maxRetries: 1 }]);
  assert.equal(sent.system, SYSTEM_PROMPT);
  assert.deepEqual(sent.messages, [{ role: 'user', content: `Budget snapshot (JSON, computed on the user's phone):\n${JSON.stringify(snapshot)}\n\nQuestion: Can I?` }]);
  for (const [ErrorClass, status] of [[RateLimitError, 429], [AuthenticationError, 503], [APIError, 502]]) {
    outcome = () => { throw new ErrorClass('upstream detail'); };
    await assert.rejects(assistant.answer({ question: 'Can I?', context: snapshot }), error => error.status === status && !error.message.includes('upstream'));
  }
  outcome = () => ({ stop_reason: 'refusal', content: [] });
  await assert.rejects(assistant.answer({ question: 'Can I?', context: snapshot }), { status: 422 });
  assert.equal(loads, 1, 'SDK is imported once, lazily');
  const plain = new TypeError('bug');
  assert.equal(mapSdkError(plain, Anthropic), plain);
  const missing = createAssistant({ anthropicApiKey: 'sk-test' }, { loadSdk: async () => { throw Object.assign(new Error('Cannot find package'), { code: 'ERR_MODULE_NOT_FOUND' }); } });
  const originalError = console.error; console.error = () => {};
  try { await assert.rejects(missing.answer({ question: 'q', context: {} }), { status: 503 }); } finally { console.error = originalError; }
});

test('config validates the session TTL and defaults the new settings', () => {
  const base = { TOKEN_ENCRYPTION_KEY: encryptionKey };
  const config = loadConfig(base);
  assert.deepEqual([config.appleBundleId, config.sessionTtlDays, config.anthropicApiKey, config.anthropicModel], ['', 30, '', 'claude-opus-5-5']);
  assert.equal(loadConfig({ ...base, MARGIN_SESSION_TTL_DAYS: '90' }).sessionTtlDays, 90);
  for (const bad of ['0', '91', '365', '1.5', 'thirty', '-3']) assert.throws(() => loadConfig({ ...base, MARGIN_SESSION_TTL_DAYS: bad }), /MARGIN_SESSION_TTL_DAYS/);
});
