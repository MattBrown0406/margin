import crypto from 'node:crypto';

const decode = value => Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
const encode = value => Buffer.from(value).toString('base64url');

export function verifyBearerToken(header, secret, now = Date.now(), claims = {}) {
  if (!secret || secret.length < 32) throw Object.assign(new Error('Server authentication is not configured'), { status: 503 });
  if (!header?.startsWith('Bearer ')) throw Object.assign(new Error('Authentication required'), { status: 401 });
  const token = header.slice(7);
  const parts = token.split('.');
  if (parts.length !== 3) throw Object.assign(new Error('Invalid session token'), { status: 401 });
  const [head, body, signature] = parts;
  const expectedSignature = crypto.createHmac('sha256', secret).update(`${head}.${body}`).digest();
  const actual = decode(signature);
  if (actual.length !== expectedSignature.length || !crypto.timingSafeEqual(actual, expectedSignature)) throw Object.assign(new Error('Invalid session token'), { status: 401 });
  let jose, payload;
  try { jose = JSON.parse(decode(head).toString('utf8')); payload = JSON.parse(decode(body).toString('utf8')); } catch { throw Object.assign(new Error('Invalid session token'), { status: 401 }); }
  if (jose?.alg !== 'HS256' || !payload || typeof payload !== 'object') throw Object.assign(new Error('Invalid session token'), { status: 401 });
  if (!payload.sub || typeof payload.sub !== 'string' || !/^[A-Za-z0-9._:-]{1,128}$/.test(payload.sub) || ['__proto__','constructor','prototype'].includes(payload.sub) || payload.sub in Object.prototype) throw Object.assign(new Error('Invalid session subject'), { status: 401 });
  if (typeof payload.exp !== 'number' || !Number.isFinite(payload.exp) || payload.exp * 1000 <= now) throw Object.assign(new Error('Session expired'), { status: 401 });
  if (typeof payload.nbf === 'number' && payload.nbf * 1000 > now) throw Object.assign(new Error('Session not yet valid'), { status: 401 });
  if (claims.issuer && payload.iss !== claims.issuer) throw Object.assign(new Error('Invalid session issuer'), { status: 401 });
  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (claims.audience && !audiences.includes(claims.audience)) throw Object.assign(new Error('Invalid session audience'), { status: 401 });
  return payload;
}

// Mints an HS256 session JWT in exactly the shape verifyBearerToken accepts.
export function signToken(payload, secret) {
  const head = encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = encode(JSON.stringify(payload));
  const sig = crypto.createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}
export const signTestToken = signToken;
