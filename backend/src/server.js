import { loadConfig } from './config.js';
import { FileStore } from './store.js';
import { PlaidClient } from './plaid.js';
import { createApp } from './app.js';

const config = loadConfig();
const store = new FileStore(config.dataFile, config.encryptionKey);
const plaid = new PlaidClient(config);
const server = createApp({ config, store, plaid });
server.listen(config.port, () => console.log(`Margin bank service listening on :${config.port} (${config.plaidEnv})`));
