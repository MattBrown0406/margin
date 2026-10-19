import { loadConfig } from './config.js';
import { FileStore } from './store.js';
import { PlaidClient } from './plaid.js';
import { createApp, retryPendingAppleRevocations } from './app.js';
import { AppleIdentityVerifier, AppleTokenClient } from './apple.js';
import { createAssistant } from './assistant.js';

const config = loadConfig();
const store = new FileStore(config.dataFile, config.encryptionKey);
// Rewrite the data file once at start so data saved by older versions is normalised on disk, not only in memory.
store.update(() => {}).catch(error => console.warn(`Data file could not be normalised: ${error?.message || 'unknown error'}`));
const plaid = new PlaidClient(config);
const apple = new AppleIdentityVerifier({ bundleId: config.appleBundleId });
const appleTokens = new AppleTokenClient({ bundleId: config.appleBundleId, teamId: config.appleTeamId, keyId: config.appleKeyId, privateKey: config.applePrivateKey });
const assistant = createAssistant(config);
const server = createApp({ config, store, plaid, apple, appleTokens: appleTokens.configured ? appleTokens : null, assistant });
// Render's proxy keeps connections open longer than Node's 5 s default; a shorter server timeout causes stray 502s.
server.keepAliveTimeout = 120_000;
server.headersTimeout = 121_000;
server.listen(config.port, () => console.log(`Bedrock bank service listening on :${config.port} (${config.plaidEnv})`));
// Apple revocations that failed during account deletion are retried at start and then hourly.
if (appleTokens.configured) {
  const retry = () => retryPendingAppleRevocations({ store, appleTokens }).catch(error => console.warn(`Pending Apple revocations could not be retried: ${error?.message || 'unknown error'}`));
  retry();
  setInterval(retry, 60 * 60 * 1000).unref();
}
