import crypto from 'node:crypto';

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_KEYS_URL = 'https://appleid.apple.com/auth/keys';
const KEY_CACHE_MS = 60 * 60 * 1000;
// A token naming an unknown kid forces a refetch; throttle that so forged kids can't make us hammer Apple.
const MIN_REFETCH_MS = 60 * 1000;
const SUBJECT = /^[A-Za-z0-9._-]{1,100}$/;

const unverified = () => Object.assign(new Error('Apple sign-in could not be verified'), { status: 401 });
const unavailable = () => Object.assign(new Error('Apple sign-in is temporarily unavailable'), { status: 503 });
const decodeJson = part => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
export const sha256Hex = value => crypto.createHash('sha256').update(value, 'utf8').digest('hex');

export class AppleIdentityVerifier {
  constructor({ bundleId, fetchImpl = fetch, now = () => Date.now() }) { this.bundleId = bundleId; this.fetch = fetchImpl; this.now = now; this.keys = null; this.fetchedAt = 0; }

  async fetchKeys() {
    let data;
    try { const response = await this.fetch(APPLE_KEYS_URL, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(10000) }); if (!response.ok) throw new Error(`HTTP ${response.status}`); data = await response.json(); }
    catch { throw unavailable(); }
    if (!Array.isArray(data?.keys)) throw unavailable();
    this.keys = data.keys; this.fetchedAt = this.now();
    return this.keys;
  }

  async keyFor(kid) {
    const stale = !this.keys || this.now() - this.fetchedAt >= KEY_CACHE_MS;
    const find = keys => keys.find(k => k && k.kid === kid && k.kty === 'RSA');
    const key = find(stale ? await this.fetchKeys() : this.keys);
    if (key || stale || this.now() - this.fetchedAt < MIN_REFETCH_MS) return key;
    return find(await this.fetchKeys()); // Apple may have rotated keys since we cached them.
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
    if (typeof claims.exp !== 'number' || !Number.isFinite(claims.exp) || claims.exp * 1000 <= this.now()) throw unverified();
    if (typeof claims.nonce !== 'string' || claims.nonce !== sha256Hex(rawNonce)) throw unverified();
    if (typeof claims.sub !== 'string' || !SUBJECT.test(claims.sub)) throw unverified();
    return claims;
  }
}
