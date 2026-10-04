import { loadConfig } from './config.js';
import { FileStore } from './store.js';
import { PlaidClient } from './plaid.js';
import { createApp } from './app.js';
import { AppleIdentityVerifier } from './apple.js';
import { createAssistant } from './assistant.js';

const config = loadConfig();
const store = new FileStore(config.dataFile, config.encryptionKey);
const plaid = new PlaidClient(config);
const apple = new AppleIdentityVerifier({ bundleId: config.appleBundleId });
const assistant = createAssistant(config);
const server = createApp({ config, store, plaid, apple, assistant });
server.listen(config.port, () => console.log(`Margin bank service listening on :${config.port} (${config.plaidEnv})`));
