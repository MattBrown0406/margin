# EveryDollar feature study — August 2, 2026

Sources reviewed:

- Ramsey's current EveryDollar product page: https://www.ramseysolutions.com/money/everydollar
- Current US App Store listing: https://apps.apple.com/us/app/everydollar-budget-management/id942571931

Current capabilities highlighted by those first-party listings:

- Zero-based monthly budgeting: give every dollar a job
- Unlimited customizable budget categories and line items
- Manual transaction tracking plus optional bank transaction streaming
- Split transactions across budget line items
- Funds/sinking funds for larger future purchases
- Bill due dates, reminders, and upcoming expenses
- Shared household budgets
- Spending/income reports and export
- Paycheck planning around pay dates and bill due dates
- Financial accounts and projected net worth
- Debt and savings goal timelines / financial roadmap
- Reordering budget items, cross-device use, and coaching content

## Margin v2 scope

Margin borrows the useful budgeting mechanics, not EveryDollar's branding, copy, visual design, or proprietary implementation.

Implemented in this iteration:

1. Zero-based `Left to assign` calculation based on expected income minus planned line items.
2. Budget groups and line items with planned, spent, and remaining values.
3. Editable planned amounts and creation of custom line items.
4. Sinking funds with a separate balance, target, and monthly-needed guidance.
5. Bills with due days and an upcoming-bills view.
6. Paycheck planning that assigns budget items to each paycheck.
7. Transaction categorization and transaction splitting.
8. Monthly spending report with category shares and income/spending summary.
9. Existing Margin differentiators: daily safe-to-spend, Peace Number, and 24-hour purchase pause.

Intentionally deferred:

- Live bank connections (requires a banking-data provider, security architecture, disclosures, and ongoing operations)
- Household cloud sync (requires accounts, conflict-safe sync, and privacy controls)
- Net-worth account aggregation
- CSV/Excel export
- Push bill reminders
- Debt snowball calculations
