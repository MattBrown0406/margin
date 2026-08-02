export function loadConfig(env = process.env) {
  const production = env.NODE_ENV === 'production';
  const config = {
    port: Number(env.PORT || 8787),
    nodeEnv: env.NODE_ENV || 'development',
    plaidEnv: env.PLAID_ENV || 'sandbox',
    plaidClientId: env.PLAID_CLIENT_ID || '',
    plaidSecret: env.PLAID_SECRET || '',
    plaidRedirectUri: env.PLAID_REDIRECT_URI || '',
    jwtSecret: env.MARGIN_JWT_SECRET || '',
    jwtIssuer: env.MARGIN_JWT_ISSUER || '',
    jwtAudience: env.MARGIN_JWT_AUDIENCE || '',
    encryptionKey: env.TOKEN_ENCRYPTION_KEY || '',
    dataFile: env.DATA_FILE || './data/margin-bank-data.json'
  };
  if (!['sandbox', 'development', 'production'].includes(config.plaidEnv)) throw new Error('PLAID_ENV must be sandbox, development, or production');
  if (production) {
    if (config.jwtSecret.length < 32) throw new Error('MARGIN_JWT_SECRET must be at least 32 characters in production');
    if (!config.jwtIssuer || !config.jwtAudience) throw new Error('MARGIN_JWT_ISSUER and MARGIN_JWT_AUDIENCE are required in production');
    if (!/^[a-f0-9]{64}$/i.test(config.encryptionKey)) throw new Error('TOKEN_ENCRYPTION_KEY must be 32 bytes encoded as 64 hex characters');
    if (!config.plaidClientId || !config.plaidSecret) throw new Error('Plaid credentials are required in production');
  }
  return config;
}
