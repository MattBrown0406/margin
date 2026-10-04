const hosts = { sandbox: 'https://sandbox.plaid.com', production: 'https://production.plaid.com' };
// Plaid asks clients to restart pagination from the original cursor when data changes mid-sync.
const MUTATION_DURING_PAGINATION = 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION';

export class PlaidClient {
  constructor(config, fetchImpl = fetch) { this.config = config; this.fetch = fetchImpl; }
  async call(path, body) {
    if (!this.config.plaidClientId || !this.config.plaidSecret) throw Object.assign(new Error('Plaid credentials are not configured'), { status: 503 });
    const response = await this.fetch(`${hosts[this.config.plaidEnv]}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ client_id: this.config.plaidClientId, secret: this.config.plaidSecret, ...body }), signal: AbortSignal.timeout(15000) });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) { const error = new Error(data.error_message || 'Plaid request failed'); error.status = data.error_code === 'ITEM_LOGIN_REQUIRED' ? 409 : 502; error.code = data.error_code; error.plaid = true; throw error; }
    return data;
  }
  createLinkToken(userId, accessToken) { return this.call('/link/token/create', { user: { client_user_id: userId }, client_name: 'Margin', ...(accessToken ? { access_token: accessToken } : { products: ['transactions'], transactions: { days_requested: 180 } }), country_codes: ['US'], language: 'en', ...(this.config.plaidRedirectUri ? { redirect_uri: this.config.plaidRedirectUri } : {}) }); }
  exchange(publicToken) { return this.call('/item/public_token/exchange', { public_token: publicToken }); }
  accounts(accessToken) { return this.call('/accounts/get', { access_token: accessToken }); }
  remove(accessToken) { return this.call('/item/remove', { access_token: accessToken }); }
  syncPage(accessToken, cursor) { return this.call('/transactions/sync', { access_token: accessToken, cursor: cursor || undefined, count: 500 }); }
  async syncAll(accessToken, initialCursor, maxRestarts = 3) {
    for (let attempt = 0; ; attempt++) {
      try { return await this.syncPages(accessToken, initialCursor); }
      catch (error) { if (error.code !== MUTATION_DURING_PAGINATION || attempt >= maxRestarts) throw error; }
    }
  }
  async syncPages(accessToken, initialCursor) {
    let cursor = initialCursor || null, added = [], modified = [], removed = [], accounts, pages = 0;
    do { const page = await this.syncPage(accessToken, cursor); added.push(...page.added); modified.push(...page.modified); removed.push(...page.removed); accounts = page.accounts || accounts; cursor = page.next_cursor; pages++; if (!page.has_more) break; if (pages >= 20) throw Object.assign(new Error('Plaid sync exceeded page safety limit'), { status: 502 }); } while (true);
    return { cursor, added, modified, removed, accounts };
  }
}
