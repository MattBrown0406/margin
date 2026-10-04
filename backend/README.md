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

All JSON. Errors are `{ "error": string, "code"?: string }`. `code` is only ever a Plaid-style upper-case code (for example `ITEM_LOGIN_REQUIRED`): passed through for 4xx errors and for Plaid's own errors, never for other 5xx.

| Route | Auth | Body | Success |
| --- | --- | --- | --- |
| `GET /health` | none | | `200 { ok, plaidEnvironment, credentialsConfigured }` |
| `POST /v1/auth/apple` | none | `{ identityToken, nonce, authorizationCode? }` | `200 { sessionToken, expiresAt, userId }` |
| `POST /v1/plaid/link-token` | bearer | `{ itemId? }` | `200 { linkToken, expiration }` |
| `POST /v1/plaid/exchange` | bearer | `{ publicToken, institutionName? }` | `201 { itemId, institutionName, accounts }` |
| `GET /v1/plaid/accounts` | bearer | | `200 { connections }` |
| `POST /v1/plaid/sync` | bearer | `{ itemId }` | `200 { added, modified, removed, accounts, transactions }` |
| `DELETE /v1/plaid/connections/:itemId` | bearer | | `200 { disconnected: true }` |
| `DELETE /v1/account` | bearer | | `200 { deleted: true }` |
| `DELETE /v1/session` | bearer | | `200 { signedOut: true }` |
| `POST /v1/ask` | bearer | `{ question, context }` | `200 { answer }` |

### Sign in with Apple → Margin session

`POST /v1/auth/apple` takes the identity token from `ASAuthorizationAppleIDCredential` and the **raw** nonce the app generated (the app sends `sha256(nonce)` hex to Apple). The service verifies the token's RS256 signature against Apple's JWKS (`https://appleid.apple.com/auth/keys`, cached for an hour; concurrent requests share one fetch, an unknown `kid` triggers at most one refetch per minute, and if Apple is unreachable the cached keys keep being used), `iss`, `aud` (= `APPLE_BUNDLE_ID`), `exp`, `iat` (no more than 10 minutes in the future or 1 day old), the hashed `nonce` (required), and `sub`. Each identity token is single use: its nonce is remembered (in memory, per process) until the token expires, and a replay gets `401`. It then mints an HS256 session JWT signed with `MARGIN_JWT_SECRET` (`sub = "apple:<Apple sub>"`, `gen` = the user's current session generation, `iat`, `iss`/`aud` from `MARGIN_JWT_ISSUER`/`MARGIN_JWT_AUDIENCE`, `exp` after `MARGIN_SESSION_TTL_DAYS`), which every bearer route accepts.

- `authorizationCode` (optional, string ≤ 1024 chars) is the `ASAuthorizationAppleIDCredential.authorizationCode`. When `APPLE_TEAM_ID`, `APPLE_KEY_ID` and `APPLE_PRIVATE_KEY` are set, it is exchanged at `https://appleid.apple.com/auth/token` (ES256 client secret). Apple's refresh token is stored encrypted on the user record, so account deletion can revoke it, only when the `sub` of the `id_token` Apple returns for that code matches the verified identity token's `sub`; otherwise a warning is logged and nothing is stored. (The `id_token` payload is decoded without re-verifying its signature: it comes straight from Apple over TLS in answer to our client-authenticated request.) A failed exchange is logged and does not fail sign-in.
- `400` missing `identityToken` (≤ 4096 chars) or `nonce` (≤ 128 chars), or an invalid `authorizationCode`
- `401` "Apple sign-in could not be verified" for any token problem
- `503` "Sign in with Apple is not configured" without `APPLE_BUNDLE_ID` or a 32+ character `MARGIN_JWT_SECRET`; `503` when Apple's keys can't be fetched

### Sessions and revocation

Every bearer route rejects an ended session with `401` "Your session has ended. Sign in again." Each user has a **session generation**: an integer, 0 until the user first revokes, kept outside the user record (so it outlives account deletion) and bumped by one, atomically, by every revocation. A session is valid only while its `gen` claim equals the current generation; a token without `gen` (for example one from an external issuer) counts as generation 0, so it stops working the first time its user revokes. No clocks are involved: signing in again right after a revocation works, and a second revocation in the same second still ends that new session.

Data files written by the earlier timestamp scheme still load: every user listed in their `revocations` starts at generation 1 (so sessions minted before the upgrade stay ended for users who had revoked, and those users sign in again), and the old field is dropped on the next write.

- `DELETE /v1/session` signs the caller out everywhere (bumps the generation, ending all of that user's sessions issued so far).
- `MARGIN_SESSION_TTL_DAYS` is 1–90 (default 30).

### Account deletion

`DELETE /v1/account` is resumable: the caller's session stays valid until the very last step, so after any failure the app retries the same request.

1. The user record is marked `deleting`. From then on a link (`POST /v1/plaid/exchange`) is refused with `409` "Account is being deleted" and the just-exchanged Item is removed at Plaid, so nothing billed is left behind. The flag stays set if deletion fails, so linking stays blocked until a retry finishes.
2. Each linked Item is revoked at Plaid (`/item/remove`; Items Plaid already forgot are treated as removed) and deleted locally. Any other Plaid failure stops the request with that error; the remaining Items and the session are kept.
3. When Apple credentials are configured and a refresh token is stored, it is revoked at `https://appleid.apple.com/auth/revoke`. If that fails, the encrypted token moves to a top-level `pendingAppleRevocations` queue (`{ token, queuedAt }`, outliving the user record) and deletion continues. The server retries the queue at start and then hourly (only with Apple credentials): an entry is dropped once Apple accepts it, kept while it fails, and dropped with a warning after 30 days. An Apple refresh token from a sign-in that lands mid-deletion goes straight to that queue.
4. One atomic store step deletes the user record and bumps the session generation together, ending every session; it refuses with `409` if an Item is somehow still stored, so an Item is never dropped without being revoked at Plaid.

Deleting an account with no data also returns `200`. A link that completes after its session ended is refused with `401` and its Item is likewise removed at Plaid.

### Ask Margin

`POST /v1/ask` sends the budget snapshot the phone computed (`context`, a plain JSON object at most 6 levels deep with at most 400 keys and array items in total, ≤ 8000 characters serialized) and a `question` (1–500 characters) to Claude, which explains the app's verdict in ≤ 120 words. The snapshot leaves the device and is sent to Anthropic, so disclose this in the privacy policy.

- `400` invalid `question` or `context`
- `422` "Margin can't help with that question." when Claude declines
- `429` "Daily question limit reached" after 30 questions per user in a rolling 24 hours (a question that fails with `429`, `502` or `503` hands its per-user and global slots back; answers and `422` refusals count); `429` "Ask Margin is at capacity today" after `ASK_DAILY_GLOBAL_LIMIT` (default 2000) questions across all users in a rolling 24 hours (both in memory, per process); `429` "Assistant is busy, try again shortly" when Anthropic rate-limits
- `502` upstream failure (including a reply cut off before any text); `503` "Ask Margin isn't configured" without `ANTHROPIC_API_KEY`

Each question is capped at `max_tokens: 3000` with `effort: "low"`, and the SDK retries a failed call at most once. A reply cut off at the token cap returns the text written so far.

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
   - `APPLE_BUNDLE_ID`: the iOS bundle identifier (required in production)
   - `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`: a Sign in with Apple key (.p8 PEM, which must be a P-256 EC key; literal `\n` allowed), so account deletion revokes the user's Apple tokens (App Store guideline 5.1.1(v)); set all three or none
   - `MARGIN_SESSION_TTL_DAYS`: session lifetime in days (default 30, 1–90)
   - `ASK_DAILY_GLOBAL_LIMIT`: Ask Margin questions per rolling day across all users (default 2000)
   - `ANTHROPIC_API_KEY` (and optionally `ANTHROPIC_MODEL`, default `claude-opus-5-5`) to enable Ask Margin, after `npm install`
4. Replace the file store with a transactional managed database or mount encrypted persistent storage with backups.
5. User sessions come from `POST /v1/auth/apple`; never bundle `MARGIN_JWT_SECRET` in the app.
6. Configure an HTTPS domain and Plaid OAuth Universal Link.
7. Add a privacy policy (including that Ask Margin sends the budget snapshot to Anthropic) and provider-required disclosures. In-app account deletion is `DELETE /v1/account`.
8. Verify Bank of America in Plaid Production Link with the account owner on a physical iPhone.

This repository intentionally contains no live credentials.
