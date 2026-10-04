import { loadConfig } from './config.js';
import { FileStore } from './store.js';
import { PlaidClient } from './plaid.js';
import { createApp } from './app.js';
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
