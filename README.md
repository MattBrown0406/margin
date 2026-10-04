# Margin

A private, local-first daily budgeting app designed to reduce unnecessary spending without shame.

## Product idea
Margin answers one useful daily question: **What can I safely spend today and still hit my goals?**

- Daily safe-to-spend number based on remaining flexible budget and days left
- True zero-based planning with a visible `Left to assign` balance
- Custom budget groups and editable line items
- Job-based intervention income with no assumed paycheck or payroll cycle
- Separate Gross (received by the business) and Net (actually transferred to personal) figures
- Separate business and personal income/expense ledgers; only personal Net funds the household plan
- Sinking funds with balances, targets, and monthly-needed guidance
- Bill due dates and an upcoming-bills view
- Monthly reports with business retained cash, personal margin, and ledger/category filters
- Real `.xlsx` export with Summary, Income & Jobs, Expenses, Budget, and Category Totals worksheets
- Savings goals with progress tracking
- A 24-hour “pause list” for wants, creating friction before impulse purchases
- Weekly insights that are specific and actionable
- Optional read-only Plaid account linking for Bank of America and other supported institutions
- Connected balances, pending/posted handling, a review-before-import inbox, deduplication, and disconnect controls
- Manual/local budgeting remains fully usable without a bank connection
- iCloud backup and sync across iPhone and iPad (SwiftData + CloudKit), with Sign in with Apple for the bank service
- Booked-job pipeline and a six-month cash-flow forecast ("December is $2,100 short unless more work books")
- Profit per job: tag business expenses to the job they served; per-job margin, and a year-to-date Schedule C summary in Reports and the Excel export
- Home-screen and lock-screen Safe to Spend widget, plus Siri/Shortcuts: "Log an expense in Margin", "What can I spend today in Margin"
- "Can I afford it?": an on-device verdict for this month or a future month, with an optional plain-English plan from Ask Margin (Claude) that only ever sees budget totals

## Interactive HTML prototype
Open `web/index.html` directly, or run:

```bash
cd web
python3 -m http.server 4173
```

Then visit `http://localhost:4173`. Data is saved to browser localStorage. The prototype exposes `resetDemo()` in its browser console to restore the sample state.

The HTML bank flow is an explicitly labeled interactive preview. It has no credential fields and never contacts a bank.

## Native iOS app
The SwiftUI source is in `ios/Margin`. It targets iOS 17 and uses SwiftData for on-device persistence.

The branded package includes a generated `Margin.xcodeproj`, so on Matt's MacBook it can be opened directly from:

```text
/Users/mattbrown/Documents/MarginBudget/Margin.xcodeproj
```

The final geometric Margin logo is installed as the native `AppIcon`, appears in the Today header, and is preserved in editable/source and export-ready form under `design/`.

If `project.yml` is changed later, regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd MarginBudget
xcodegen generate
open Margin.xcodeproj
```

The native target resolves Plaid's official `LinkKit` Swift package. Real bank linking also requires the authenticated service in `backend/`.

## Apple Developer setup (required to build to a device)

The app now uses capabilities that need a paid Apple Developer team. In Xcode, select your team for **both** the `Margin` and `MarginWidget` targets, then make sure these identifiers exist (Xcode's Signing & Capabilities tab can create them):

| Capability | Identifier | Used for |
|---|---|---|
| iCloud › CloudKit | `iCloud.com.mattbrown.margin` | Backup and sync |
| App Groups (app and widget) | `group.com.mattbrown.margin` | Sharing today's numbers with the widget |
| Sign in with Apple | — | Signing in to the bank service and Ask Margin |
| Background Modes › Remote notifications | — | CloudKit sync pushes |

If you change the bundle prefix, update `ios/Margin/Margin.entitlements`, `ios/MarginWidget/MarginWidget.entitlements`, and `WidgetSnapshot.appGroup`. Without iCloud the app quietly keeps data on the device; sync can also be turned off in Settings.

New installs start with the starter budget only (no sample transactions), because with iCloud sync sample entries would reach every device.

## Tests

```bash
swift test            # money logic: safe-to-spend, forecast, job profit, Schedule C, affordability
cd backend && npm test
```

## Secure bank service

The backend exchanges Plaid's one-time public tokens, encrypts long-lived access tokens with AES-256-GCM, and exposes authenticated read-only account, transaction-sync, and disconnect routes. Plaid credentials and access tokens are never returned to the app or written to logs.

Run its integration tests with:

```bash
cd backend
npm test
```

## Bank connection production gate

A live Bank of America connection requires a Plaid developer application, Production approval, an HTTPS backend deployment, and a real signed user session. Set the `MARGIN_API_BASE_URL` build setting (passed to the app through `ios/Margin/Info.plist`) to that deployment and provision the user session into iOS Keychain after authentication. Never place `PLAID_SECRET`, `MARGIN_JWT_SECRET`, or `TOKEN_ENCRYPTION_KEY` in the repository or iOS bundle.

## Privacy
Budgeting remains local-first. When bank sync is enabled, only the selected account metadata and transaction data needed for budgeting crosses the authenticated backend. Margin requests Plaid's `transactions` product only—never payments, transfers, identity, or money movement.
