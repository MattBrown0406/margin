import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { once } from 'node:events';
import { createApp } from '../src/app.js';
import { FileStore } from '../src/store.js';
import { signTestToken } from '../src/auth.js';

const secret = 'test-jwt-secret-that-is-at-least-thirty-two-characters';
const encryptionKey = '11'.repeat(32);
class FakePlaid {
  constructor() { this.removed = false; }
  async createLinkToken(user) { return { link_token: `link-${user}`, expiration: '2030-01-01T00:00:00Z' }; }
  async exchange(token) { assert.equal(token, 'public-sandbox'); return { access_token: 'access-secret-never-returned', item_id: 'item-bofa' }; }
  async accounts(token) { assert.equal(token, 'access-secret-never-returned'); return { accounts: [{ account_id: 'acct-checking', name: 'Adv Plus Banking', official_name: 'Bank of America Advantage Plus Banking', type: 'depository', subtype: 'checking', mask: '0406', balances: { current: 4200, available: 3900, iso_currency_code: 'USD' } }] }; }
  async syncAll(token, cursor) { assert.equal(token, 'access-secret-never-returned'); return { cursor: cursor || 'cursor-1', added: [{ transaction_id: 'tx-1', account_id: 'acct-checking', merchant_name: 'Market of Choice', amount: 82.14, date: '2026-08-02', pending: false, personal_finance_category: { primary: 'FOOD_AND_DRINK' } }], modified: [], removed: [] }; }
  async remove(token) { assert.equal(token, 'access-secret-never-returned'); this.removed = true; return {}; }
}

async function fixture() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'margin-plaid-')), file = path.join(dir, 'data.json');
  const config = { plaidEnv: 'sandbox', plaidClientId: 'client', plaidSecret: 'secret', plaidRedirectUri: '', jwtSecret: secret, jwtIssuer: 'margin-test', jwtAudience: 'margin-bank-api' };
  const plaid = new FakePlaid(), store = new FileStore(file, encryptionKey), server = createApp({ config, plaid, store });
  server.listen(0); await once(server, 'listening'); const base = `http://127.0.0.1:${server.address().port}`;
  const token = signTestToken({ sub: 'matt', iss: 'margin-test', aud: 'margin-bank-api', exp: Math.floor(Date.now()/1000)+300 }, secret);
  const request = (url, options={}) => fetch(base+url, { ...options, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...(options.headers||{}) } });
  return { dir, file, plaid, server, request, close: async()=>{server.close();await once(server,'close');await fs.rm(dir,{recursive:true,force:true});} };
}

test('rejects unauthenticated bank access', async () => { const f=await fixture(); try { const r=await fetch(`http://127.0.0.1:${f.server.address().port}/v1/plaid/accounts`); assert.equal(r.status,401); } finally { await f.close(); } });
test('links, encrypts, syncs, and disconnects without exposing access tokens', async () => { const f=await fixture(); try {
  let r=await f.request('/v1/plaid/link-token',{method:'POST'}), data=await r.json(); assert.equal(r.status,200); assert.equal(data.linkToken,'link-matt');
  r=await f.request('/v1/plaid/exchange',{method:'POST',body:JSON.stringify({publicToken:'public-sandbox',institutionName:'Bank of America'})}); data=await r.json(); assert.equal(r.status,201); assert.equal(data.accounts[0].mask,'0406'); assert.equal(JSON.stringify(data).includes('access-secret'),false);
  const disk=await fs.readFile(f.file,'utf8'); assert.equal(disk.includes('access-secret-never-returned'),false); assert.equal(disk.includes('item-bofa'),true);
  r=await f.request('/v1/plaid/sync',{method:'POST',body:JSON.stringify({itemId:'item-bofa'})}); data=await r.json(); assert.equal(data.added,1); assert.equal(data.transactions[0].name,'Market of Choice');
  r=await f.request('/v1/plaid/connections/item-bofa',{method:'DELETE'}); data=await r.json(); assert.equal(data.disconnected,true); assert.equal(f.plaid.removed,true);
  r=await f.request('/v1/plaid/accounts'); data=await r.json(); assert.deepEqual(data.connections,[]);
  const afterDisconnect=JSON.parse(await fs.readFile(f.file,'utf8')); assert.deepEqual(afterDisconnect.users.matt.transactions,{});
 } finally { await f.close(); } });
test('production config cannot start with weak secrets', async () => { const { loadConfig } = await import('../src/config.js'); assert.throws(()=>loadConfig({NODE_ENV:'production',PLAID_ENV:'production',MARGIN_JWT_SECRET:'short'}),/at least 32/); });
test('rejects wrong token audience', async () => { const f=await fixture(); try { const wrong=signTestToken({sub:'matt',iss:'margin-test',aud:'other-api',exp:Math.floor(Date.now()/1000)+300},secret); const r=await fetch(`http://127.0.0.1:${f.server.address().port}/v1/plaid/accounts`,{headers:{authorization:`Bearer ${wrong}`}}); assert.equal(r.status,401); } finally { await f.close(); } });
