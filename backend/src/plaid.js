const hosts = { sandbox: 'https://sandbox.plaid.com', development: 'https://development.plaid.com', production: 'https://production.plaid.com' };

export class PlaidClient {
  constructor(config, fetchImpl = fetch) { this.config = config; this.fetch = fetchImpl; }
  async call(path, body) {
    if (!this.config.plaidClientId || !this.config.plaidSecret) throw Object.assign(new Error('Plaid credentials are not configured'), { status: 503 });
    const response = await this.fetch(`${hosts[this.config.plaidEnv]}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ client_id: this.config.plaidClientId, secret: this.config.plaidSecret, ...body }), signal: AbortSignal.timeout(15000) });
    const data = await response.json();
    if (!response.ok) { const error = new Error(data.error_message || 'Plaid request failed'); error.status = data.error_code === 'ITEM_LOGIN_REQUIRED' ? 409 : 502; error.code = data.error_code; throw error; }
    return data;
  }
  createLinkToken(userId) { return this.call('/link/token/create', { user: { client_user_id: userId }, client_name: 'Margin', products: ['transactions'], optional_products: [], country_codes: ['US'], language: 'en', transactions: { days_requested: 180 }, ...(this.config.plaidRedirectUri ? { redirect_uri: this.config.plaidRedirectUri } : {}) }); }
  exchange(publicToken) { return this.call('/item/public_token/exchange', { public_token: publicToken }); }
  accounts(accessToken) { return this.call('/accounts/get', { access_token: accessToken }); }
  remove(accessToken) { return this.call('/item/remove', { access_token: accessToken }); }
  syncPage(accessToken, cursor) { return this.call('/transactions/sync', { access_token: accessToken, cursor: cursor || undefined, count: 500 }); }
  async syncAll(accessToken, initialCursor) {
    let cursor = initialCursor || null, added = [], modified = [], removed = [], pages = 0;
    do { const page = await this.syncPage(accessToken, cursor); added.push(...page.added); modified.push(...page.modified); removed.push(...page.removed); cursor = page.next_cursor; pages++; if (!page.has_more) break; if (pages >= 20) throw Object.assign(new Error('Plaid sync exceeded page safety limit'), { status: 502 }); } while (true);
    return { cursor, added, modified, removed };
  }
}
