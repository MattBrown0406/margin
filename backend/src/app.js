import http from 'node:http';
import { verifyBearerToken, signToken, isRevoked, sessionEnded } from './auth.js';
import { createAskLimiter, isAskContext } from './assistant.js';
import { MAX_SESSION_TTL_DAYS } from './config.js';

const json = (res, status, body) => { const data = JSON.stringify(body); res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(data), 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' }); res.end(data); };
const cleanText = (value, max = 100) => typeof value === 'string' ? value.trim().slice(0, max) : '';
const httpError = (status, message) => Object.assign(new Error(message), { status });
async function body(req) { let size = 0, chunks = []; for await (const chunk of req) { size += chunk.length; if (size > 32768) throw httpError(413, 'Request body too large'); chunks.push(chunk); } if (!chunks.length) return {}; try { return JSON.parse(Buffer.concat(chunks).toString('utf8')) ?? {}; } catch { throw httpError(400, 'Invalid JSON'); } }
const mapAccount = a => ({ id: a.account_id, name: cleanText(a.name), officialName: cleanText(a.official_name), type: a.type, subtype: a.subtype, mask: cleanText(a.mask, 8), currentBalance: a.balances?.current ?? null, availableBalance: a.balances?.available ?? null, currency: a.balances?.iso_currency_code || 'USD' });
const mapTransaction = t => ({ id: t.transaction_id, accountId: t.account_id, name: cleanText(t.merchant_name || t.name), amount: t.amount, date: t.authorized_date || t.date, pending: Boolean(t.pending), category: t.personal_finance_category?.primary || 'GENERAL_MERCHANDISE' });
// Plaid no longer knows this Item, so there is nothing left to revoke remotely.
const ALREADY_REMOVED = new Set(['ITEM_NOT_FOUND', 'INVALID_ACCESS_TOKEN']);
// Plaid-style error codes only; numeric or system codes (23, ENOTDIR) never reach a client.
const ERROR_CODE = /^[A-Z][A-Z0-9_]{2,63}$/;
const publicCode = (error, status) => typeof error.code === 'string' && ERROR_CODE.test(error.code) && (status < 500 || error.plaid === true) ? error.code : undefined;
const GLOBAL_ASK_KEY = '*';

// apple/appleTokens/assistant are optional: without them their routes answer 503 (or, for appleTokens,
// Apple token exchange/revocation is skipped) and everything else works. `now` is injectable for tests.
export function createApp({ config, plaid, store, apple = null, appleTokens = null, assistant = null, askLimiter = createAskLimiter(), askGlobalLimiter = createAskLimiter({ limit: config.askDailyGlobalLimit || 2000 }), now = () => Date.now() }) {
  const nowS = () => Math.floor(now() / 1000);
  const warn = (message, error) => console.warn(`${message}: ${error?.message || 'unknown error'}`);
  // Revokes the Item at Plaid (tolerating Items Plaid already forgot) before dropping it locally,
  // so a failed revoke never leaves a billed Item we can no longer reach.
  const disconnect = async (userId, itemId) => {
    const accessToken = await store.getAccessToken(userId, itemId);
    try { await plaid.remove(accessToken); } catch (error) { if (!ALREADY_REMOVED.has(error.code)) throw error; }
    await store.removeItem(userId, itemId);
  };
  return http.createServer(async (req, res) => {
    try {
      const { pathname } = new URL(req.url || '/', 'http://localhost');
      if (req.method === 'GET' && pathname === '/health') return json(res, 200, { ok: true, plaidEnvironment: config.plaidEnv, credentialsConfigured: Boolean(config.plaidClientId && config.plaidSecret) });
      if (req.method === 'POST' && pathname === '/v1/auth/apple') {
        if (!apple || !config.appleBundleId || !config.jwtSecret || config.jwtSecret.length < 32) throw httpError(503, 'Sign in with Apple is not configured');
        const input = await body(req), identityToken = typeof input.identityToken === 'string' ? input.identityToken : '', nonce = typeof input.nonce === 'string' ? input.nonce : '', authorizationCode = input.authorizationCode ?? '';
        if (!identityToken || identityToken.length > 4096 || !nonce || nonce.length > 128) throw httpError(400, 'identityToken and nonce are required');
        if (typeof authorizationCode !== 'string' || authorizationCode.length > 1024) throw httpError(400, 'authorizationCode must be a string of at most 1024 characters');
        const claims = await apple.verify(identityToken, nonce), userId = `apple:${claims.sub}`;
        // Kept so account deletion can revoke the user's Apple tokens; never allowed to fail sign-in.
        if (authorizationCode && appleTokens?.configured) {
          try { const refreshToken = await appleTokens.exchange(authorizationCode); if (refreshToken) await store.saveAppleRefreshToken(userId, refreshToken); }
          catch (error) { warn('Apple authorization code exchange failed', error); }
        }
        // iat is always after the user's last revocation (see isRevoked), so a new sign-in is never born revoked.
        const revokedAt = await store.sessionsRevokedAt(userId);
        const iat = Math.max(nowS(), (revokedAt ?? -1) + 1), exp = iat + Math.min(config.sessionTtlDays || 30, MAX_SESSION_TTL_DAYS) * 86400;
        const sessionToken = signToken({ sub: userId, ...(config.jwtIssuer ? { iss: config.jwtIssuer } : {}), ...(config.jwtAudience ? { aud: config.jwtAudience } : {}), iat, exp }, config.jwtSecret);
        return json(res, 200, { sessionToken, expiresAt: new Date(exp * 1000).toISOString(), userId });
      }
      const session = verifyBearerToken(req.headers.authorization, config.jwtSecret, now(), { issuer: config.jwtIssuer, audience: config.jwtAudience });
      const userId = session.sub;
      if (isRevoked(session.iat, await store.sessionsRevokedAt(userId))) throw sessionEnded();

      if (req.method === 'POST' && pathname === '/v1/plaid/link-token') {
        // With an itemId this creates an update-mode token so the user can repair a broken login.
        const input = await body(req), itemId = cleanText(input.itemId, 128);
        const accessToken = itemId ? await store.getAccessToken(userId, itemId) : undefined;
        const result = await plaid.createLinkToken(userId, accessToken);
        return json(res, 200, { linkToken: result.link_token, expiration: result.expiration });
      }
      if (req.method === 'POST' && pathname === '/v1/plaid/exchange') {
        const input = await body(req), publicToken = cleanText(input.publicToken, 512), institutionName = cleanText(input.institutionName) || 'Connected institution';
        if (!publicToken) throw httpError(400, 'publicToken is required');
        const exchanged = await plaid.exchange(publicToken);
        // Persist the access token before any further call can fail, so the Item is never orphaned
        // (still billed by Plaid but impossible to disconnect).
        // saveItem refuses once this session was revoked (e.g. the account was deleted mid-link); the new
        // Item is then removed at Plaid so nothing billed is left behind.
        try { await store.saveItem(userId, { itemId: exchanged.item_id, accessToken: exchanged.access_token, institutionName, accounts: [] }, session.iat); }
        catch (error) { try { await plaid.remove(exchanged.access_token); } catch (removeError) { warn('Could not remove an unsaved Plaid Item', removeError); } throw error; }
        let accounts = [];
        try { accounts = (await plaid.accounts(exchanged.access_token)).accounts.map(mapAccount); await store.updateItem(userId, exchanged.item_id, { accounts }); }
        catch { /* Accounts are refreshed on the next sync. */ }
        return json(res, 201, { itemId: exchanged.item_id, institutionName, accounts });
      }
      if (req.method === 'GET' && pathname === '/v1/plaid/accounts') {
        const user = await store.getUser(userId);
        const connections = Object.entries(user.items).map(([itemId, item]) => ({ itemId, institutionName: item.institutionName, accounts: item.accounts, linkedAt: item.linkedAt, lastSyncedAt: item.lastSyncedAt || null, requiresAttention: Boolean(item.requiresAttention) }));
        return json(res, 200, { connections });
      }
      if (req.method === 'POST' && pathname === '/v1/plaid/sync') {
        const input = await body(req), itemId = cleanText(input.itemId, 128);
        if (!itemId) throw httpError(400, 'itemId is required');
        const user = await store.getUser(userId), item = Object.hasOwn(user.items, itemId) ? user.items[itemId] : undefined;
        if (!item) throw httpError(404, 'Bank connection not found');
        const accessToken = await store.getAccessToken(userId, itemId);
        let synced;
        try { synced = await plaid.syncAll(accessToken, item.cursor); }
        catch (error) { if (error.code === 'ITEM_LOGIN_REQUIRED') await store.updateItem(userId, itemId, { requiresAttention: true }); throw error; }
        const result = await store.applySync(userId, itemId, { ...synced, accounts: synced.accounts?.map(mapAccount) });
        const transactions = result.transactions.map(mapTransaction).sort((a, b) => String(b.date).localeCompare(String(a.date)));
        return json(res, 200, { added: result.added, modified: result.modified, removed: result.removed, accounts: result.accounts, transactions });
      }
      const removeMatch = pathname.match(/^\/v1\/plaid\/connections\/([^/]+)$/);
      if (req.method === 'DELETE' && removeMatch) {
        let itemId; try { itemId = decodeURIComponent(removeMatch[1]); } catch { throw httpError(400, 'Invalid connection id'); }
        await disconnect(userId, itemId);
        return json(res, 200, { disconnected: true });
      }
      if (req.method === 'DELETE' && pathname === '/v1/account') {
        // Items are revoked one by one; a non-recoverable Plaid failure stops here so the rest stay
        // reachable and the client can retry. The user record goes only once no Items remain.
        // Once Items are gone: revoke Apple tokens (best effort), end every session (which also stops
        // a link racing this request from saving), revoke anything linked before that, delete the user.
        const disconnectAll = async () => { for (const itemId of Object.keys((await store.getUser(userId)).items)) await disconnect(userId, itemId); };
        await disconnectAll();
        if (appleTokens?.configured) {
          try { const refreshToken = await store.getAppleRefreshToken(userId); if (refreshToken) await appleTokens.revoke(refreshToken); }
          catch (error) { warn('Apple token revocation failed', error); }
        }
        await store.revokeSessions(userId, nowS());
        await disconnectAll();
        await store.deleteUser(userId);
        return json(res, 200, { deleted: true });
      }
      if (req.method === 'DELETE' && pathname === '/v1/session') {
        // Sign out everywhere: every session issued up to now stops working.
        await store.revokeSessions(userId, nowS());
        return json(res, 200, { signedOut: true });
      }
      if (req.method === 'POST' && pathname === '/v1/ask') {
        if (!assistant) throw httpError(503, "Ask Margin isn't configured");
        const input = await body(req), question = typeof input.question === 'string' ? input.question.trim() : '', context = input.context;
        if (!question || question.length > 500) throw httpError(400, 'question must be 1-500 characters');
        let size = Infinity;
        if (isAskContext(context)) try { size = JSON.stringify(context).length; } catch { /* rejected below */ }
        if (size > 8000) throw httpError(400, 'context must be an object of at most 8000 characters');
        if (!askLimiter.take(userId)) throw httpError(429, 'Daily question limit reached');
        if (!askGlobalLimiter.take(GLOBAL_ASK_KEY)) { askLimiter.release(userId); throw httpError(429, 'Ask Margin is at capacity today'); }
        return json(res, 200, { answer: await assistant.answer({ question, context }) });
      }
      return json(res, 404, { error: 'Not found' });
    } catch (error) {
      const status = Number(error.status) || 500;
      // Only our own fixed messages (expose) may describe a 5xx; anything else could leak upstream detail.
      const safeMessage = status >= 500 && status !== 503 && !error.expose ? 'Bank service temporarily unavailable' : error.message;
      return json(res, status, { error: safeMessage, code: publicCode(error, status) });
    }
  });
}
