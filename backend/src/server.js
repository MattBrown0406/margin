import { loadConfig } from './config.js';
import { FileStore } from './store.js';
import { PlaidClient } from './plaid.js';
import { createApp, retryPendingAppleRevocations } from './app.js';
import { AppleIdentityVerifier, AppleTokenClient } from './apple.js';
import { createAssistant } from './assistant.js';

const config = loadConfig();
const store = new FileStore(config.dataFile, config.encryptionKey);
const plaid = new PlaidClient(config);
const apple = new AppleIdentityVerifier({ bundleId: config.appleBundleId });
const appleTokens = new AppleTokenClient({ bundleId: config.appleBundleId, teamId: config.appleTeamId, keyId: config.appleKeyId, privateKey: config.applePrivateKey });
const assistant = createAssistant(config);
const server = createApp({ config, store, plaid, apple, appleTokens: appleTokens.configured ? appleTokens : null, assistant });
server.listen(config.port, () => console.log(`Margin bank service listening on :${config.port} (${config.plaidEnv})`));
// Apple revocations that failed during account deletion are retried at start and then hourly.
if (appleTokens.configured) {
  const retry = () => retryPendingAppleRevocations({ store, appleTokens }).catch(error => console.warn(`Pending Apple revocations could not be retried: ${error?.message || 'unknown error'}`));
  retry();
  setInterval(retry, 60 * 60 * 1000).unref();
}
