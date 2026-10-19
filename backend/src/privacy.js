// The privacy policy the app links to from Settings and App Store Connect lists: GET /privacy.
// Keep it in step with what the app and this service actually collect.
export const PRIVACY_UPDATED = 'October 18, 2026';

// appleRevocation: whether this deployment can revoke Sign in with Apple (APPLE_TEAM_ID/KEY_ID/PRIVATE_KEY set).
export const privacyPolicyHtml = ({ appleRevocation = false } = {}) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stabilis Privacy Policy</title>
<style>body{font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:680px;margin:0 auto;padding:24px 16px 48px;color:#1D3A41;background:#FBF8F1}h1{font-size:28px}h2{font-size:19px;margin-top:28px}</style>
</head><body>
<h1>Stabilis Privacy Policy</h1>
<p>Last updated ${PRIVACY_UPDATED}.</p>
<p>Stabilis is a budgeting app. This policy explains what it collects, where that data goes, and how to delete it. Stabilis has no ads, does not track you across apps or websites, and never sells your data.</p>

<h2>Your budget stays with you</h2>
<p>Your budget, transactions, jobs, goals, debts and settings are stored on your device and, if you leave iCloud sync on, in your own private iCloud account. We cannot see this data.</p>

<h2>Signing in</h2>
<p>Bank connections and Ask Stabilis require Sign in with Apple. Our service stores only the anonymous user identifier Apple provides${appleRevocation ? ', plus a token used to revoke the sign-in when you delete your account' : ''}. We do not receive or store your name or email address.</p>

<h2>Bank connections (Plaid)</h2>
<p>If you connect a bank, the connection is made through Plaid Inc. You log in to your bank inside Plaid's screens; Stabilis never sees your bank password. Plaid's handling of your data is described in the <a href="https://plaid.com/legal/#end-user-privacy-policy">Plaid End User Privacy Policy</a>.</p>
<p>Our service stores the access Plaid grants (encrypted) plus your connected accounts (name, last four digits, type, balances) and their transactions (merchant or description, amount, date, whether pending, category), so the app can show them for you to review. These are kept on our service's private, access-controlled disk. Access is read-only: Stabilis cannot move money. This data is kept until you disconnect the bank or delete your account.</p>

<h2>Ask Stabilis (AI)</h2>
<p>Ask Stabilis is optional and asks your permission the first time you use it. When you ask, the app sends a summary of your budget (category names and totals, bills, a cash-flow forecast, your savings goal) and the purchase you describe through our service to Claude, an AI model by Anthropic, PBC, to write the answer. Individual transactions and bank details are never sent. Our service passes the request on without keeping your questions or the answers. Anthropic processes it under its <a href="https://www.anthropic.com/legal/commercial-terms">Commercial Terms</a>, which do not allow it to train models on this data.</p>

<h2>Notifications</h2>
<p>Bill, Net and tax reminders are scheduled on your device. Nothing about them is sent to us.</p>

<h2>Deleting your data</h2>
<p>In Stabilis, open Settings and tap Delete account. This disconnects every bank at Plaid and deletes everything our service stores about you${appleRevocation ? ', and revokes your Sign in with Apple authorization' : ''}. ${appleRevocation ? 'Two things are' : 'One thing is'} kept: a counter tied to your anonymous Apple identifier, so sessions that were signed in before the deletion stay signed out${appleRevocation ? ', and, if Apple could not be reached, the token needed to retry the revocation, for up to 30 days' : ''}. ${appleRevocation ? '' : 'To stop using Sign in with Apple with Stabilis, open the Settings app, tap your name, then Sign-In &amp; Security › Sign in with Apple. '}To remove the budget itself, delete the app and, in iCloud settings, the app's iCloud data.</p>

<h2>Service logs</h2>
<p>Our hosting provider records standard request logs (such as IP address, time and the address requested) to keep the service running and secure. They do not contain your budget, bank data or questions.</p>

<h2>Children</h2>
<p>Stabilis is not directed to children under 13 and does not knowingly collect their data.</p>

<h2>Changes and contact</h2>
<p>If this policy changes, the date above changes with it. Questions: use the support link on the Stabilis App Store page.</p>
</body></html>
`;
