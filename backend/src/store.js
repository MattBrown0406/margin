import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { isCurrentSession, sessionEnded } from './auth.js';

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

// Ids come from tokens and request bodies; only own keys count, so "toString" etc. never resolve to Object.prototype.
const own = (object, key) => (object && Object.hasOwn(object, key) ? object[key] : undefined);
const writableKey = key => { if (typeof key !== 'string' || !key || key in Object.prototype) throw Object.assign(new Error('Invalid id'), { status: 400 }); return key; };
const newUser = () => ({ items: {}, transactions: {} });
const generationOf = (data, userId) => { const value = own(data.sessionGenerations, userId); return Number.isSafeInteger(value) && value >= 0 ? value : 0; };
const deletingError = () => Object.assign(new Error('Account is being deleted'), { status: 409 });
// Pending Apple revocations are matched by their encrypted record (random IV), never by user.
const sameRevocation = (a, b) => a?.token?.iv === b?.token?.iv && a?.token?.data === b?.token?.data;

export class FileStore {
  constructor(file, encryptionKey) { this.file = file; this.key = encryptionKey; this.queue = Promise.resolve(); }
  // Files from the old timestamp scheme still carry `revocations`: a user listed there starts at generation 1,
  // so sessions minted under that scheme (which carry no `gen`) stay ended. The field is dropped on the next write.
  async read() {
    let data; try { data = JSON.parse(await fs.readFile(this.file, 'utf8')); } catch (error) { if (error.code === 'ENOENT') data = { users: {} }; else throw error; }
    if (!data.sessionGenerations || typeof data.sessionGenerations !== 'object') data.sessionGenerations = {};
    if (!Array.isArray(data.pendingAppleRevocations)) data.pendingAppleRevocations = [];
    if (data.revocations && typeof data.revocations === 'object') for (const userId of Object.keys(data.revocations)) if (!(userId in Object.prototype) && !Object.hasOwn(data.sessionGenerations, userId)) data.sessionGenerations[userId] = 1;
    delete data.revocations;
    return data;
  }
  async write(data) { await fs.mkdir(path.dirname(this.file), { recursive: true }); const temp = `${this.file}.${process.pid}.tmp`; await fs.writeFile(temp, JSON.stringify(data, null, 2), { mode: 0o600 }); await fs.rename(temp, this.file); }
  update(work) { const next = this.queue.then(async () => { const data = await this.read(); const result = await work(data); await this.write(data); return result; }); this.queue = next.catch(() => {}); return next; }
  // sessionGen is the `gen` of the session asking. Refused inside the serialized update once that session has
  // ended (401) or while the account is being deleted (409), so a link racing deletion is never stored.
  async saveItem(userId, item, sessionGen) { return this.update(data => { if (!isCurrentSession(sessionGen, generationOf(data, userId))) throw sessionEnded(); if (own(data.users, userId)?.deleting) throw deletingError(); if (!own(data.users, userId)) data.users[writableKey(userId)] = newUser(); data.users[userId].items[writableKey(item.itemId)] = { institutionName: item.institutionName, cursor: null, accounts: item.accounts || [], token: encryptToken(item.accessToken, this.key), linkedAt: new Date().toISOString() }; return data.users[userId].items[item.itemId]; }); }
  async getUser(userId) { const data = await this.read(); return own(data.users, userId) || { items: {}, transactions: {} }; }
  async getAccessToken(userId, itemId) { const user = await this.getUser(userId), item = own(user.items, itemId); if (!item) throw Object.assign(new Error('Bank connection not found'), { status: 404 }); return decryptToken(item.token, this.key); }
  async applySync(userId, itemId, result) { return this.update(data => { const user = own(data.users, userId); if (!own(user?.items, itemId)) throw Object.assign(new Error('Bank connection not found'), { status: 404 }); for (const t of result.added) user.transactions[t.transaction_id] = { ...t, margin_item_id: itemId }; for (const t of result.modified) user.transactions[t.transaction_id] = { ...t, margin_item_id: itemId }; for (const t of result.removed) delete user.transactions[t.transaction_id]; const item = user.items[itemId]; item.cursor = result.cursor; item.lastSyncedAt = new Date().toISOString(); item.requiresAttention = false; if (result.accounts) item.accounts = result.accounts; return { added: result.added.length, modified: result.modified.length, removed: result.removed.length, accounts: item.accounts, transactions: Object.values(user.transactions).filter(t => t.margin_item_id === itemId) }; }); }
  async updateItem(userId, itemId, changes) { return this.update(data => { const item = own(own(data.users, userId)?.items, itemId); if (!item) return null; Object.assign(item, changes); return item; }); }
  // Step one of account deletion: from here on saveItem refuses, so no Item can appear behind the Plaid sweep.
  // Creates the record if needed, so even a user with no data is protected.
  async beginDeletion(userId, sessionGen) { return this.update(data => { if (!isCurrentSession(sessionGen, generationOf(data, userId))) throw sessionEnded(); if (!own(data.users, userId)) data.users[writableKey(userId)] = newUser(); data.users[userId].deleting = true; return true; }); }
  // Final step of account deletion, atomic: refuses while Items remain (so one is never dropped without being
  // revoked at Plaid), otherwise deletes the user and ends every session together.
  async deleteUser(userId) { return this.update(data => { writableKey(userId); const user = own(data.users, userId); if (user && Object.keys(user.items).length) throw Object.assign(new Error('Account changed during deletion; try again'), { status: 409 }); if (user) delete data.users[userId]; data.sessionGenerations[userId] = generationOf(data, userId) + 1; return true; }); }
  // Generations live outside users so they outlive account deletion; they only ever move forward.
  async revokeSessions(userId) { return this.update(data => { writableKey(userId); data.sessionGenerations[userId] = generationOf(data, userId) + 1; return data.sessionGenerations[userId]; }); }
  async sessionGeneration(userId) { return generationOf(await this.read(), userId); }
  // A sign-in landing mid-deletion queues its token for revocation instead of attaching it to a doomed record.
  async saveAppleRefreshToken(userId, refreshToken, queuedAt = new Date().toISOString()) { return this.update(data => { const token = encryptToken(refreshToken, this.key); if (own(data.users, userId)?.deleting) { data.pendingAppleRevocations.push({ token, queuedAt }); return false; } if (!own(data.users, userId)) data.users[writableKey(userId)] = newUser(); data.users[userId].appleRefreshToken = token; return true; }); }
  // Moves the user's encrypted Apple refresh token to the top-level retry queue (it outlives the user record).
  async queueAppleRevocation(userId, queuedAt) { return this.update(data => { const user = own(data.users, userId), token = own(user, 'appleRefreshToken'); if (!token) return false; data.pendingAppleRevocations.push({ token, queuedAt }); delete user.appleRefreshToken; return true; }); }
  // refreshToken is null when an entry can't be decrypted; it then stays queued until it expires.
  async pendingAppleRevocations() { return (await this.read()).pendingAppleRevocations.map(entry => { let refreshToken = null; try { refreshToken = decryptToken(entry.token, this.key); } catch { /* kept until it expires */ } return { ...entry, refreshToken }; }); }
  async dropPendingAppleRevocations(entries) { return this.update(data => { data.pendingAppleRevocations = data.pendingAppleRevocations.filter(entry => !entries.some(done => sameRevocation(entry, done))); return data.pendingAppleRevocations.length; }); }
  async getAppleRefreshToken(userId) { const record = own(own((await this.read()).users, userId), 'appleRefreshToken'); return record ? decryptToken(record, this.key) : null; }
  async removeItem(userId, itemId) { return this.update(data => { const user = own(data.users, userId); if (!own(user?.items, itemId)) return false; delete user.items[itemId]; for (const [id, transaction] of Object.entries(user.transactions)) if (transaction.margin_item_id === itemId) delete user.transactions[id]; return true; }); }
}
