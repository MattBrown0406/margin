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

## Routes

All JSON. Errors are `{ "error": string, "code"?: string }`.

| Route | Auth | Body | Success |
| --- | --- | --- | --- |
| `GET /health` | none | | `200 { ok, plaidEnvironment, credentialsConfigured }` |
| `POST /v1/auth/apple` | none | `{ identityToken, nonce }` | `200 { sessionToken, expiresAt, userId }` |
| `POST /v1/plaid/link-token` | bearer | `{ itemId? }` | `200 { linkToken, expiration }` |
| `POST /v1/plaid/exchange` | bearer | `{ publicToken, institutionName? }` | `201 { itemId, institutionName, accounts }` |
| `GET /v1/plaid/accounts` | bearer | | `200 { connections }` |
| `POST /v1/plaid/sync` | bearer | `{ itemId }` | `200 { added, modified, removed, accounts, transactions }` |
| `DELETE /v1/plaid/connections/:itemId` | bearer | | `200 { disconnected: true }` |
| `DELETE /v1/account` | bearer | | `200 { deleted: true }` |
| `POST /v1/ask` | bearer | `{ question, context }` | `200 { answer }` |

### Sign in with Apple → Margin session

`POST /v1/auth/apple` takes the identity token from `ASAuthorizationAppleIDCredential` and the **raw** nonce the app generated (the app sends `sha256(nonce)` hex to Apple). The service verifies the token's RS256 signature against Apple's JWKS (`https://appleid.apple.com/auth/keys`, cached for an hour and refetched once when an unknown `kid` appears), `iss`, `aud` (= `APPLE_BUNDLE_ID`), `exp`, the hashed `nonce` (required), and `sub`. It then mints an HS256 session JWT signed with `MARGIN_JWT_SECRET` (`sub = "apple:<Apple sub>"`, `iss`/`aud` from `MARGIN_JWT_ISSUER`/`MARGIN_JWT_AUDIENCE`, `exp` after `MARGIN_SESSION_TTL_DAYS`), which every bearer route accepts.

- `400` missing `identityToken` (≤ 4096 chars) or `nonce` (≤ 128 chars)
- `401` "Apple sign-in could not be verified" for any token problem
- `503` "Sign in with Apple is not configured" without `APPLE_BUNDLE_ID` or a 32+ character `MARGIN_JWT_SECRET`; `503` when Apple's keys can't be fetched

### Account deletion

`DELETE /v1/account` revokes each linked Item at Plaid (`/item/remove`; Items Plaid already forgot are treated as removed), deletes it locally, then deletes the user record. If Plaid fails for any other reason the request stops with that error and the remaining Items are kept, so the app can retry. Deleting an account with no data also returns `200`.

### Ask Margin

`POST /v1/ask` sends the budget snapshot the phone computed (`context`, a JSON object ≤ 8000 characters serialized) and a `question` (1–500 characters) to Claude, which explains the app's verdict in ≤ 120 words. The snapshot leaves the device and is sent to Anthropic, so disclose this in the privacy policy.

- `400` invalid `question` or `context`
- `422` "Margin can't help with that question." when Claude declines
- `429` "Daily question limit reached" after 30 questions per user in a rolling 24 hours (in memory, per process); `429` "Assistant is busy, try again shortly" when Anthropic rate-limits
- `502` upstream failure; `503` "Ask Margin isn't configured" without `ANTHROPIC_API_KEY`

Ask Margin uses the official `@anthropic-ai/sdk` package, loaded only on the first question. Run `npm install` in `backend/` before enabling it; the other routes and the tests need no dependencies.

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
   - `APPLE_BUNDLE_ID`: the iOS bundle identifier, to enable Sign in with Apple
   - `MARGIN_SESSION_TTL_DAYS`: session lifetime in days (default 30, 1–365)
   - `ANTHROPIC_API_KEY` (and optionally `ANTHROPIC_MODEL`, default `claude-opus-5-5`) to enable Ask Margin, after `npm install`
4. Replace the file store with a transactional managed database or mount encrypted persistent storage with backups.
5. User sessions come from `POST /v1/auth/apple`; never bundle `MARGIN_JWT_SECRET` in the app.
6. Configure an HTTPS domain and Plaid OAuth Universal Link.
7. Add a privacy policy (including that Ask Margin sends the budget snapshot to Anthropic) and provider-required disclosures. In-app account deletion is `DELETE /v1/account`.
8. Verify Bank of America in Plaid Production Link with the account owner on a physical iPhone.

This repository intentionally contains no live credentials.
