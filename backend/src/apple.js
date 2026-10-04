import crypto from 'node:crypto';

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_KEYS_URL = 'https://appleid.apple.com/auth/keys';
const APPLE_TOKEN_URL = 'https://appleid.apple.com/auth/token';
const APPLE_REVOKE_URL = 'https://appleid.apple.com/auth/revoke';
const KEY_CACHE_MS = 60 * 60 * 1000;
// A token naming an unknown kid forces a refetch; throttle that (on the last attempt, success or not)
// so forged kids can't make us hammer Apple.
const MIN_REFETCH_MS = 60 * 1000;
// With nothing cached at all, a failed fetch is retried at most this often.
const COLD_RETRY_MS = 5 * 1000;
const MAX_FUTURE_IAT_S = 10 * 60, MAX_AGE_S = 24 * 60 * 60;
const SUBJECT = /^[A-Za-z0-9._-]{1,100}$/;

const unverified = () => Object.assign(new Error('Apple sign-in could not be verified'), { status: 401 });
const unavailable = () => Object.assign(new Error('Apple sign-in is temporarily unavailable'), { status: 503 });
const decodeJson = part => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
export const sha256Hex = value => crypto.createHash('sha256').update(value, 'utf8').digest('hex');

export class AppleIdentityVerifier {
  constructor({ bundleId, fetchImpl = fetch, now = () => Date.now() }) { this.bundleId = bundleId; this.fetch = fetchImpl; this.now = now; this.keys = null; this.fetchedAt = 0; this.attemptedAt = -Infinity; this.inflight = null; this.usedNonces = new Map(); }

  async fetchKeys() {
    let data;
    try { const response = await this.fetch(APPLE_KEYS_URL, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(10000) }); if (!response.ok) throw new Error(`HTTP ${response.status}`); data = await response.json(); }
    catch { throw unavailable(); }
    if (!Array.isArray(data?.keys)) throw unavailable();
    this.keys = data.keys; this.fetchedAt = this.now();
    return this.keys;
  }

  // Single flight: concurrent callers share one request. Throws 503 only when there is no cached key
  // set to fall back on; otherwise a failed refetch keeps serving the (stale) cached keys.
  async refresh() {
    if (!this.inflight) { this.attemptedAt = this.now(); this.inflight = this.fetchKeys().finally(() => { this.inflight = null; }); }
    try { return await this.inflight; } catch (error) { if (this.keys) return this.keys; throw error; }
  }

  async keyFor(kid) {
    const find = keys => keys.find(k => k && k.kid === kid && k.kty === 'RSA');
    const sinceAttempt = this.now() - this.attemptedAt;
    if (!this.keys) { if (!this.inflight && sinceAttempt < COLD_RETRY_MS) throw unavailable(); return find(await this.refresh()); }
    const expired = this.now() - this.fetchedAt >= KEY_CACHE_MS;
    if (this.inflight || (expired && sinceAttempt >= MIN_REFETCH_MS)) return find(await this.refresh());
    const key = find(this.keys);
    if (key || sinceAttempt < MIN_REFETCH_MS) return key;
    return find(await this.refresh()); // Apple may have rotated keys since we cached them.
  }

  // An identity token is single use: its nonce hash is remembered until the token expires.
  consumeNonce(nonceHash, expMs) {
    const now = this.now();
    for (const [hash, until] of this.usedNonces) if (until <= now) this.usedNonces.delete(hash);
    if (this.usedNonces.has(nonceHash)) throw unverified();
    this.usedNonces.set(nonceHash, expMs);
  }

  // Returns the verified claims; throws 401 for any token problem and 503 when Apple's keys are unreachable.
  async verify(identityToken, rawNonce) {
    if (!this.bundleId) throw Object.assign(new Error('Sign in with Apple is not configured'), { status: 503 });
    if (typeof identityToken !== 'string' || typeof rawNonce !== 'string' || !rawNonce) throw unverified();
    const parts = identityToken.split('.');
    if (parts.length !== 3 || parts.some(p => !/^[A-Za-z0-9_-]+$/.test(p))) throw unverified();
    const [h, p, s] = parts;
    let header, claims;
    try { header = decodeJson(h); claims = decodeJson(p); } catch { throw unverified(); }
    if (header?.alg !== 'RS256' || typeof header.kid !== 'string' || !claims || typeof claims !== 'object') throw unverified();
    const jwk = await this.keyFor(header.kid);
    if (!jwk) throw unverified();
    let valid = false;
    try { valid = crypto.verify('RSA-SHA256', Buffer.from(`${h}.${p}`), crypto.createPublicKey({ key: jwk, format: 'jwk' }), Buffer.from(s, 'base64url')); } catch { valid = false; }
    if (!valid) throw unverified();
    const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (claims.iss !== APPLE_ISSUER || !audiences.includes(this.bundleId)) throw unverified();
    const nowS = this.now() / 1000;
    if (typeof claims.exp !== 'number' || !Number.isFinite(claims.exp) || claims.exp <= nowS) throw unverified();
    if (typeof claims.iat !== 'number' || !Number.isFinite(claims.iat) || claims.iat > nowS + MAX_FUTURE_IAT_S || claims.iat < nowS - MAX_AGE_S) throw unverified();
    if (typeof claims.nonce !== 'string' || claims.nonce !== sha256Hex(rawNonce)) throw unverified();
    if (typeof claims.sub !== 'string' || !SUBJECT.test(claims.sub)) throw unverified();
    this.consumeNonce(claims.nonce, claims.exp * 1000);
    return claims;
  }
}

// Apple REST client for the account-deletion requirement (App Store guideline 5.1.1(v)): exchanges the
// app's authorization code for a refresh token at sign-in and revokes it when the account is deleted.
export class AppleTokenClient {
  constructor({ bundleId, teamId, keyId, privateKey, fetchImpl = fetch, now = () => Date.now() }) { this.bundleId = bundleId || ''; this.teamId = teamId || ''; this.keyId = keyId || ''; this.privateKey = (privateKey || '').replace(/\\n/g, '\n'); this.fetch = fetchImpl; this.now = now; }
  get configured() { return Boolean(this.bundleId && this.teamId && this.keyId && this.privateKey); }

  // ES256 client secret JWT, valid for five minutes.
  clientSecret() {
    const iat = Math.floor(this.now() / 1000), encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    const data = `${encode({ alg: 'ES256', kid: this.keyId })}.${encode({ iss: this.teamId, iat, exp: iat + 300, aud: APPLE_ISSUER, sub: this.bundleId })}`;
    return `${data}.${crypto.sign('sha256', Buffer.from(data), { key: this.privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
  }

  // Errors carry only the HTTP status and Apple's error code, never the code, secret, or tokens.
  async post(url, form) {
    if (!this.configured) throw Object.assign(new Error('Apple token client is not configured'), { status: 503 });
    const response = await this.fetch(url, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' }, body: new URLSearchParams({ client_id: this.bundleId, client_secret: this.clientSecret(), ...form }).toString(), signal: AbortSignal.timeout(10000) });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) { const code = typeof data?.error === 'string' && /^[a-z_]{1,64}$/.test(data.error) ? ` ${data.error}` : ''; throw Object.assign(new Error(`Apple ${new URL(url).pathname} failed: HTTP ${response.status}${code}`), { status: 502 }); }
    return data;
  }

  // Returns Apple's refresh token, or null when the response carries none.
  async exchange(code) { const data = await this.post(APPLE_TOKEN_URL, { code, grant_type: 'authorization_code' }); return typeof data?.refresh_token === 'string' && data.refresh_token ? data.refresh_token : null; }
  async revoke(refreshToken) { await this.post(APPLE_REVOKE_URL, { token: refreshToken, token_type_hint: 'refresh_token' }); }
}
