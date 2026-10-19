// The privacy policy the app links to from Settings and App Store Connect lists: GET /privacy.
// Keep it in step with what the app and this service actually collect.
export const PRIVACY_UPDATED = 'October 18, 2026';

export const privacyPolicyHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Bedrock Privacy Policy</title>
<style>body{font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:680px;margin:0 auto;padding:24px 16px 48px;color:#1D3A41;background:#FBF8F1}h1{font-size:28px}h2{font-size:19px;margin-top:28px}</style>
</head><body>
<h1>Bedrock Privacy Policy</h1>
<p>Last updated ${PRIVACY_UPDATED}.</p>
<p>Bedrock is a budgeting app. This policy explains what it collects, where that data goes, and how to delete it. Bedrock has no ads, does not track you across apps or websites, and never sells your data.</p>

<h2>Your budget stays with you</h2>
<p>Your budget, transactions, jobs, goals, debts and settings are stored on your device and, if you leave iCloud sync on, in your own private iCloud account. We cannot see this data.</p>

<h2>Signing in</h2>
<p>Bank connections and Ask Bedrock require Sign in with Apple. Our service stores only the anonymous user identifier Apple provides (and, if Apple supplies one, a token used to revoke the sign-in when you delete your account). We do not receive or store your name or email address.</p>

<h2>Bank connections (Plaid)</h2>
<p>If you connect a bank, the connection is made through Plaid Inc. You log in to your bank inside Plaid's screens; Bedrock never sees your bank password. Plaid's handling of your data is described in the <a href="https://plaid.com/legal/#end-user-privacy-policy">Plaid End User Privacy Policy</a>.</p>
<p>Our service stores, encrypted, the access Plaid grants plus your connected accounts (name, last four digits, type, balance) and their transactions (merchant, amount, date, category), so the app can show them for you to review. Access is read-only: Bedrock cannot move money. This data is kept until you disconnect the bank or delete your account.</p>

<h2>Ask Bedrock (AI)</h2>
<p>Ask Bedrock is optional and asks your permission the first time you use it. When you ask, the app sends a summary of your budget (category totals, bills, a cash-flow forecast, your savings goal) and the purchase you describe to Claude, an AI model by Anthropic, PBC, to write the answer. Individual transactions and bank details are never sent. Our service does not keep your questions or the answers. Anthropic's handling is described in its <a href="https://www.anthropic.com/legal/privacy">Privacy Policy</a>.</p>

<h2>Notifications</h2>
<p>Bill, Net and tax reminders are scheduled on your device. Nothing about them is sent to us.</p>

<h2>Deleting your data</h2>
<p>In Bedrock, open Settings and tap Delete account. This disconnects every bank at Plaid, deletes everything our service stores about you, and revokes your Sign in with Apple authorization. To remove the budget itself, delete the app and, in iCloud settings, Bedrock's iCloud data.</p>

<h2>Children</h2>
<p>Bedrock is not directed to children under 13 and does not knowingly collect their data.</p>

<h2>Changes and contact</h2>
<p>If this policy changes, the date above changes with it. Questions: use the support link on Bedrock's App Store page.</p>
</body></html>
`;
