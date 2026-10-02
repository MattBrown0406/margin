import http from 'node:http';
import { verifyBearerToken } from './auth.js';

const json = (res, status, body) => { const data = JSON.stringify(body); res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(data), 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' }); res.end(data); };
const cleanText = (value, max = 100) => typeof value === 'string' ? value.trim().slice(0, max) : '';
const httpError = (status, message) => Object.assign(new Error(message), { status });
async function body(req) { let size = 0, chunks = []; for await (const chunk of req) { size += chunk.length; if (size > 32768) throw httpError(413, 'Request body too large'); chunks.push(chunk); } if (!chunks.length) return {}; try { return JSON.parse(Buffer.concat(chunks).toString('utf8')) ?? {}; } catch { throw httpError(400, 'Invalid JSON'); } }
const mapAccount = a => ({ id: a.account_id, name: cleanText(a.name), officialName: cleanText(a.official_name), type: a.type, subtype: a.subtype, mask: cleanText(a.mask, 8), currentBalance: a.balances?.current ?? null, availableBalance: a.balances?.available ?? null, currency: a.balances?.iso_currency_code || 'USD' });
const mapTransaction = t => ({ id: t.transaction_id, accountId: t.account_id, name: cleanText(t.merchant_name || t.name), amount: t.amount, date: t.authorized_date || t.date, pending: Boolean(t.pending), category: t.personal_finance_category?.primary || 'GENERAL_MERCHANDISE' });
// Plaid no longer knows this Item, so there is nothing left to revoke remotely.
const ALREADY_REMOVED = new Set(['ITEM_NOT_FOUND', 'INVALID_ACCESS_TOKEN']);

export function createApp({ config, plaid, store }) {
  return http.createServer(async (req, res) => {
    try {
      const { pathname } = new URL(req.url || '/', 'http://localhost');
      if (req.method === 'GET' && pathname === '/health') return json(res, 200, { ok: true, plaidEnvironment: config.plaidEnv, credentialsConfigured: Boolean(config.plaidClientId && config.plaidSecret) });
      const session = verifyBearerToken(req.headers.authorization, config.jwtSecret, Date.now(), { issuer: config.jwtIssuer, audience: config.jwtAudience });
      const userId = session.sub;

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
        await store.saveItem(userId, { itemId: exchanged.item_id, accessToken: exchanged.access_token, institutionName, accounts: [] });
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
        const accessToken = await store.getAccessToken(userId, itemId);
        try { await plaid.remove(accessToken); } catch (error) { if (!ALREADY_REMOVED.has(error.code)) throw error; }
        await store.removeItem(userId, itemId);
        return json(res, 200, { disconnected: true });
      }
      return json(res, 404, { error: 'Not found' });
    } catch (error) {
      const status = Number(error.status) || 500;
      const safeMessage = status >= 500 && status !== 503 ? 'Bank service temporarily unavailable' : error.message;
      return json(res, status, { error: safeMessage, code: error.code || undefined });
    }
  });
}
