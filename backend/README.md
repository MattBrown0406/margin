# Margin bank-sync service

A small read-only Plaid backend for Margin. The iOS app never receives Plaid secrets or long-lived access tokens.

## Security boundary

- Plaid Link handles bank credentials, OAuth, and MFA.
- The app receives a short-lived Link token and returns a one-time public token.
- This service exchanges the public token, encrypts the access token with AES-256-GCM, and stores it server-side.
- Every account/sync/disconnect route requires a signed user session.
- Only `transactions` is requested. Transfer, payment, identity, investments, and liabilities permissions are not requested.
- No access token, Plaid secret, or bank credential is returned to the app or written to logs.
- When a bank login expires, sync returns 409 and the connection is flagged `requiresAttention`; `POST /v1/plaid/link-token` with `{ "itemId" }` returns an update-mode token to repair it.
- `TOKEN_ENCRYPTION_KEY` is required in every environment, and `PLAID_ENV` must be `sandbox` or `production` (Plaid retired `development`).

## Local tests

```bash
cd backend
npm test
```

## Production requirements

1. Create a Plaid account and request Production access.
2. Generate independent secrets:
   - `MARGIN_JWT_SECRET`: at least 32 random characters
   - `MARGIN_JWT_ISSUER`: your trusted authentication issuer
   - `MARGIN_JWT_AUDIENCE`: the bank API audience (for example `margin-bank-api`)
   - `TOKEN_ENCRYPTION_KEY`: `openssl rand -hex 32`
3. Provide `PLAID_CLIENT_ID` and the environment-specific `PLAID_SECRET` through the deployment platform's encrypted secret store.
4. Replace the file store with a transactional managed database or mount encrypted persistent storage with backups.
5. Issue user JWTs from a real authentication boundary (Sign in with Apple or an existing identity provider); never bundle `MARGIN_JWT_SECRET` in the app.
6. Configure an HTTPS domain and Plaid OAuth Universal Link.
7. Add a privacy policy, data deletion workflow, and provider-required disclosures.
8. Verify Bank of America in Plaid Production Link with the account owner on a physical iPhone.

This repository intentionally contains no live credentials.
