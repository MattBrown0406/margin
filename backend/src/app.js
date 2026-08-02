import http from 'node:http';
import { verifyBearerToken } from './auth.js';

const json = (res, status, body) => { const data = JSON.stringify(body); res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(data), 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' }); res.end(data); };
const cleanText = (value, max = 100) => typeof value === 'string' ? value.trim().slice(0, max) : '';
async function body(req) { let size = 0, chunks = []; for await (const chunk of req) { size += chunk.length; if (size > 32768) throw Object.assign(new Error('Request body too large'), { status: 413 }); chunks.push(chunk); } if (!chunks.length) return {}; try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw Object.assign(new Error('Invalid JSON'), { status: 400 }); } }

export function createApp({ config, plaid, store }) {
  return http.createServer(async (req, res) => {
    try {
      if (req.method === 'GET' && req.url === '/health') return json(res, 200, { ok: true, plaidEnvironment: config.plaidEnv, credentialsConfigured: Boolean(config.plaidClientId && config.plaidSecret) });
      const session = verifyBearerToken(req.headers.authorization, config.jwtSecret, Date.now(), { issuer: config.jwtIssuer, audience: config.jwtAudience });
      const userId = session.sub;

      if (req.method === 'POST' && req.url === '/v1/plaid/link-token') {
        const result = await plaid.createLinkToken(userId);
        return json(res, 200, { linkToken: result.link_token, expiration: result.expiration });
      }
      if (req.method === 'POST' && req.url === '/v1/plaid/exchange') {
        const input = await body(req), publicToken = cleanText(input.publicToken, 512), institutionName = cleanText(input.institutionName) || 'Connected institution';
        if (!publicToken) throw Object.assign(new Error('publicToken is required'), { status: 400 });
        const exchanged = await plaid.exchange(publicToken);
        const accountResult = await plaid.accounts(exchanged.access_token);
        const accounts = accountResult.accounts.map(a => ({ id: a.account_id, name: cleanText(a.name), officialName: cleanText(a.official_name), type: a.type, subtype: a.subtype, mask: cleanText(a.mask, 8), currentBalance: a.balances?.current ?? null, availableBalance: a.balances?.available ?? null, currency: a.balances?.iso_currency_code || 'USD' }));
        await store.saveItem(userId, { itemId: exchanged.item_id, accessToken: exchanged.access_token, institutionName, accounts });
        return json(res, 201, { itemId: exchanged.item_id, institutionName, accounts });
      }
      if (req.method === 'GET' && req.url === '/v1/plaid/accounts') {
        const user = await store.getUser(userId);
        const connections = Object.entries(user.items).map(([itemId, item]) => ({ itemId, institutionName: item.institutionName, accounts: item.accounts, linkedAt: item.linkedAt, lastSyncedAt: item.lastSyncedAt || null, requiresAttention: false }));
        return json(res, 200, { connections });
      }
      if (req.method === 'POST' && req.url === '/v1/plaid/sync') {
        const input = await body(req), itemId = cleanText(input.itemId, 128);
        if (!itemId) throw Object.assign(new Error('itemId is required'), { status: 400 });
        const user = await store.getUser(userId), item = user.items[itemId];
        if (!item) throw Object.assign(new Error('Bank connection not found'), { status: 404 });
        const accessToken = await store.getAccessToken(userId, itemId);
        const synced = await plaid.syncAll(accessToken, item.cursor);
        const result = await store.applySync(userId, itemId, synced);
        const transactions = result.transactions.map(t => ({ id: t.transaction_id, accountId: t.account_id, name: cleanText(t.merchant_name || t.name), amount: t.amount, date: t.authorized_date || t.date, pending: Boolean(t.pending), category: t.personal_finance_category?.primary || 'GENERAL_MERCHANDISE' }));
        return json(res, 200, { added: result.added, modified: result.modified, removed: result.removed, transactions });
      }
      const removeMatch = req.url?.match(/^\/v1\/plaid\/connections\/([^/?]+)$/);
      if (req.method === 'DELETE' && removeMatch) {
        const itemId = decodeURIComponent(removeMatch[1]), accessToken = await store.getAccessToken(userId, itemId);
        await plaid.remove(accessToken); await store.removeItem(userId, itemId);
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
