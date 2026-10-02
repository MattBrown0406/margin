import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

function keyFromHex(hex) {
  if (!/^[a-f0-9]{64}$/i.test(hex)) throw new Error('TOKEN_ENCRYPTION_KEY must be 64 hexadecimal characters');
  return Buffer.from(hex, 'hex');
}

export function encryptToken(value, keyHex) {
  const iv = crypto.randomBytes(12), key = keyFromHex(keyHex), cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return { v: 1, iv: iv.toString('base64url'), tag: cipher.getAuthTag().toString('base64url'), data: encrypted.toString('base64url') };
}
export function decryptToken(record, keyHex) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', keyFromHex(keyHex), Buffer.from(record.iv, 'base64url'));
  decipher.setAuthTag(Buffer.from(record.tag, 'base64url'));
  return Buffer.concat([decipher.update(Buffer.from(record.data, 'base64url')), decipher.final()]).toString('utf8');
}

export class FileStore {
  constructor(file, encryptionKey) { this.file = file; this.key = encryptionKey; this.queue = Promise.resolve(); }
  async read() { try { return JSON.parse(await fs.readFile(this.file, 'utf8')); } catch (error) { if (error.code === 'ENOENT') return { users: {} }; throw error; } }
  async write(data) { await fs.mkdir(path.dirname(this.file), { recursive: true }); const temp = `${this.file}.${process.pid}.tmp`; await fs.writeFile(temp, JSON.stringify(data, null, 2), { mode: 0o600 }); await fs.rename(temp, this.file); }
  update(work) { const next = this.queue.then(async () => { const data = await this.read(); const result = await work(data); await this.write(data); return result; }); this.queue = next.catch(() => {}); return next; }
  async saveItem(userId, item) { return this.update(data => { data.users[userId] ||= { items: {}, transactions: {} }; data.users[userId].items[item.itemId] = { institutionName: item.institutionName, cursor: null, accounts: item.accounts || [], token: encryptToken(item.accessToken, this.key), linkedAt: new Date().toISOString() }; return data.users[userId].items[item.itemId]; }); }
  async getUser(userId) { const data = await this.read(); return data.users[userId] || { items: {}, transactions: {} }; }
  async getAccessToken(userId, itemId) { const user = await this.getUser(userId), item = user.items[itemId]; if (!item) throw Object.assign(new Error('Bank connection not found'), { status: 404 }); return decryptToken(item.token, this.key); }
  async applySync(userId, itemId, result) { return this.update(data => { const user = data.users[userId]; if (!user?.items[itemId]) throw Object.assign(new Error('Bank connection not found'), { status: 404 }); for (const t of result.added) user.transactions[t.transaction_id] = { ...t, margin_item_id: itemId }; for (const t of result.modified) user.transactions[t.transaction_id] = { ...t, margin_item_id: itemId }; for (const t of result.removed) delete user.transactions[t.transaction_id]; const item = user.items[itemId]; item.cursor = result.cursor; item.lastSyncedAt = new Date().toISOString(); item.requiresAttention = false; if (result.accounts) item.accounts = result.accounts; return { added: result.added.length, modified: result.modified.length, removed: result.removed.length, accounts: item.accounts, transactions: Object.values(user.transactions).filter(t => t.margin_item_id === itemId) }; }); }
  async updateItem(userId, itemId, changes) { return this.update(data => { const item = data.users[userId]?.items[itemId]; if (!item) return null; Object.assign(item, changes); return item; }); }
  async removeItem(userId, itemId) { return this.update(data => { const user = data.users[userId]; if (!user?.items[itemId]) return false; delete user.items[itemId]; for (const [id, transaction] of Object.entries(user.transactions)) if (transaction.margin_item_id === itemId) delete user.transactions[id]; return true; }); }
}
