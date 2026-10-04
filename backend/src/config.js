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
    dataFile: env.DATA_FILE || './data/margin-bank-data.json',
    appleBundleId: env.APPLE_BUNDLE_ID || '',
    sessionTtlDays: env.MARGIN_SESSION_TTL_DAYS ? Number(env.MARGIN_SESSION_TTL_DAYS) : 30,
    anthropicApiKey: env.ANTHROPIC_API_KEY || '',
    anthropicModel: env.ANTHROPIC_MODEL || 'claude-opus-5-5'
  };
  if (!['sandbox', 'production'].includes(config.plaidEnv)) throw new Error('PLAID_ENV must be sandbox or production (Plaid retired its development environment)');
  if (!Number.isInteger(config.sessionTtlDays) || config.sessionTtlDays < 1 || config.sessionTtlDays > 365) throw new Error('MARGIN_SESSION_TTL_DAYS must be a whole number of days from 1 to 365');
  if (production) {
    if (config.jwtSecret.length < 32) throw new Error('MARGIN_JWT_SECRET must be at least 32 characters in production');
    if (!config.jwtIssuer || !config.jwtAudience) throw new Error('MARGIN_JWT_ISSUER and MARGIN_JWT_AUDIENCE are required in production');
    if (!config.plaidClientId || !config.plaidSecret) throw new Error('Plaid credentials are required in production');
  }
  // Checked in every environment: without it the first link would exchange (and spend) the
  // public token, then fail to store the access token.
  if (!/^[a-f0-9]{64}$/i.test(config.encryptionKey)) throw new Error('TOKEN_ENCRYPTION_KEY must be 32 bytes encoded as 64 hex characters');
  return config;
}
