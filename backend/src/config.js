import crypto from 'node:crypto';

export const MAX_SESSION_TTL_DAYS = 90;

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
    // Sign in with Apple REST credentials (optional): enable token revocation on account deletion.
    appleTeamId: env.APPLE_TEAM_ID || '',
    appleKeyId: env.APPLE_KEY_ID || '',
    applePrivateKey: (env.APPLE_PRIVATE_KEY || '').replace(/\\n/g, '\n'),
    sessionTtlDays: env.MARGIN_SESSION_TTL_DAYS ? Number(env.MARGIN_SESSION_TTL_DAYS) : 30,
    anthropicApiKey: env.ANTHROPIC_API_KEY || '',
    anthropicModel: env.ANTHROPIC_MODEL || 'claude-opus-5-5',
    askDailyGlobalLimit: env.ASK_DAILY_GLOBAL_LIMIT ? Number(env.ASK_DAILY_GLOBAL_LIMIT) : 2000
  };
  if (!['sandbox', 'production'].includes(config.plaidEnv)) throw new Error('PLAID_ENV must be sandbox or production (Plaid retired its development environment)');
  if (!Number.isInteger(config.sessionTtlDays) || config.sessionTtlDays < 1 || config.sessionTtlDays > MAX_SESSION_TTL_DAYS) throw new Error(`MARGIN_SESSION_TTL_DAYS must be a whole number of days from 1 to ${MAX_SESSION_TTL_DAYS}`);
  if (!Number.isInteger(config.askDailyGlobalLimit) || config.askDailyGlobalLimit < 1) throw new Error('ASK_DAILY_GLOBAL_LIMIT must be a positive whole number');
  const appleCredentials = [config.appleTeamId, config.appleKeyId, config.applePrivateKey];
  if (appleCredentials.some(Boolean)) {
    if (!appleCredentials.every(Boolean)) throw new Error('APPLE_TEAM_ID, APPLE_KEY_ID and APPLE_PRIVATE_KEY must be set together');
    try { crypto.createPrivateKey(config.applePrivateKey); } catch { throw new Error('APPLE_PRIVATE_KEY must be the .p8 PEM private key'); }
  }
  if (production) {
    if (config.jwtSecret.length < 32) throw new Error('MARGIN_JWT_SECRET must be at least 32 characters in production');
    if (!config.jwtIssuer || !config.jwtAudience) throw new Error('MARGIN_JWT_ISSUER and MARGIN_JWT_AUDIENCE are required in production');
    if (!config.plaidClientId || !config.plaidSecret) throw new Error('Plaid credentials are required in production');
    if (!config.appleBundleId) throw new Error('APPLE_BUNDLE_ID is required in production');
  }
  // Checked in every environment: without it the first link would exchange (and spend) the
  // public token, then fail to store the access token.
  if (!/^[a-f0-9]{64}$/i.test(config.encryptionKey)) throw new Error('TOKEN_ENCRYPTION_KEY must be 32 bytes encoded as 64 hex characters');
  return config;
}
