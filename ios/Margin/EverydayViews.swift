import SwiftUI
import SwiftData
import UserNotifications

// MARK: - Editing an entry

/// Edits an existing entry. Expenses can change everything; income keeps its kind (Gross or Net), since jobs,
/// bookings, and transfers are linked through it — to change that, delete the entry and add it again.
struct TransactionEditView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    let tx: Transaction
    @Query private var categories: [BudgetCategory]
    @Query private var rules: [MerchantRule]
    @Query private var allocations: [NetAllocation]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @State private var title = ""; @State private var amount = ""; @State private var isRefund = false; @State private var date = Date()
    @State private var scope = "personal"; @State private var category = ""; @State private var essential = true; @State private var jobID: UUID?
    @State private var loaded = false

    private var personalNames: [String] { categories.sorted { ($0.groupName, $0.name) < ($1.groupName, $1.name) }.map(\.name) }
    /// The ledger's categories, plus the entry's own if it no longer exists (so the picker is never empty or invalid).
    private var categoryOptions: [String] {
        let base = scope == "business" ? businessCategoryNames : personalNames
        return scope == tx.ledgerScope && !tx.category.isEmpty && !base.contains(tx.category) ? base + [tx.category] : base
    }
    /// Jobs a business expense can be charged to: recent ones, plus the one it's already charged to.
    private var jobs: [Transaction] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: .now) ?? .distantPast
        return transactions.filter { $0.isIncome && $0.incomeKind == "gross" && $0.jobID != nil && ($0.date >= cutoff || $0.jobID == tx.jobID) }
    }
    private var value: Double? { Double(moneyInput: amount) }
    /// For an edited Net transfer: how far this month's assignable Net (this month's Net plus late Net carried in from
    /// last month, as Assign Net counts it) would fall below what's already assigned — counting the edit, including
    /// moving the transfer out of this month.
    private var netOverAssigned: Double? {
        guard tx.incomeKind == "net", tx.ledgerScope == "personal", let value else { return nil }
        // The Net transfers as they'd be after saving, run through the same rules Assign Net uses.
        let nets = NetAssignment.personalNets(transactions.filter { $0.id != tx.id }) + [(date: date, amount: value)]
        let calendar = Calendar.current
        let available = nets.filter { calendar.isDate($0.date, equalTo: .now, toGranularity: .month) }.reduce(0) { $0 + $1.amount }
            + NetAssignment.carriedIn(nets: nets, allocations: allocations)
        let gap = NetAssignment.assignedThisMonth(allocations).reduce(0) { $0 + $1.amount } - available
        return gap > 0.5 ? gap : nil
    }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value != nil && (tx.isIncome || categoryOptions.contains(category)) }

    var body: some View { NavigationStack { Form {
        Section {
            TextField("Description", text: $title)
            LabeledContent("Amount") { TextField("0", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            if !tx.isIncome { Toggle("Refund (money back)", isOn: $isRefund) }
            DatePicker("Date", selection: $date, displayedComponents: .date)
        } footer: { if tx.externalID != nil { Text("Imported from your bank.") } }
        if tx.isIncome {
            Section {
                LabeledContent("Type", value: tx.incomeKind == "gross" ? "Gross received by the business" : tx.incomeKind == "net" ? "Net transferred to personal" : "Income")
                if let over = netOverAssigned {
                    Label("This month would have \(over.money) more assigned than Net to assign. Undo an assignment in Assign Net to match.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.marginCoral)
                }
            } footer: { Text("To change the type, delete this entry and add it again.") }
        } else {
            Section("Ledger") {
                Picker("Account", selection: $scope) { Text("Personal").tag("personal"); Text("Business").tag("business") }.pickerStyle(.segmented)
                Picker("Category", selection: $category) { ForEach(categoryOptions, id: \.self) { Text($0).tag($0) } }
                if scope == "personal" { Toggle("This was necessary", isOn: $essential) }
                if scope == "business", !jobs.isEmpty {
                    Picker("For job", selection: $jobID) {
                        Text("Not tied to a job").tag(UUID?.none)
                        ForEach(jobs) { job in Text("\(job.title) · \(job.date.formatted(date: .abbreviated, time: .omitted))").tag(job.jobID) }
                    }
                }
            }
        }
    }.numberPadDone().navigationTitle("Edit entry")
     .onAppear(perform: load)
     .onChange(of: scope) { if loaded, !categoryOptions.contains(category) { category = categoryOptions.first ?? "" } }
     .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
     } } }

    private func load() {
        guard !loaded else { return }
        title = tx.title; amount = String(format: "%.2f", abs(tx.amount)); isRefund = !tx.isIncome && tx.amount < 0; date = tx.date
        scope = tx.ledgerScope; category = tx.category; essential = tx.isEssential; jobID = tx.jobID
        loaded = true
    }

    private func save() {
        // iCloud de-duplication can remove this copy while the sheet is open; writing to it then would crash.
        guard tx.modelContext != nil, !tx.isDeleted else { dismiss(); return }
        guard let value else { return }
        let originalTitle = tx.title, oldDate = tx.date
        tx.title = title.trimmingCharacters(in: .whitespacesAndNewlines); tx.date = date
        if tx.isIncome {
            tx.amount = value
            // A job's tax set-aside keeps its amount (that money really moved; Undo on the job card changes it) and
            // follows the job to its corrected month.
            if tx.incomeKind == "gross", let id = tx.jobID?.uuidString, oldDate != date {
                for decision in allocations where decision.target == id && JobTaxSetAside.isDecision(decision) {
                    decision.monthStart = Calendar.current.startOfMonth(for: date); decision.monthKey = Calendar.current.monthKey(for: date)
                }
            }
        } else {
            let changedCategory = category != tx.category || scope != tx.ledgerScope
            tx.amount = isRefund ? -value : value
            tx.ledgerScope = scope; tx.category = category; tx.isEssential = scope == "personal" ? essential : true
            tx.jobID = scope == "business" ? jobID : nil
            // A corrected category is the one to use for this merchant next time — under the bank's original
            // description too, since that's what the next import will carry.
            if changedCategory {
                // One rule per distinct merchant key (the rules list doesn't see rows inserted during this save).
                var seen = Set<String>()
                for name in [tx.title, originalTitle, tx.externalName ?? ""] {
                    guard let key = MerchantRules.learnableKey(name), seen.insert(key).inserted else { continue }
                    MerchantRule.learn(title: name, scope: scope, category: category, rules: rules, in: context)
                }
            }
        }
        try? context.save(); dismiss()
    }
}

// MARK: - Tax set-aside from job payments

enum JobTaxSetAside {
    /// Jobs paid recently enough to still offer a set-aside.
    static let offerDays = 45

    /// The tax year a job's Gross belongs to: its own year (a job paid in early January counts toward the new year, even
    /// while last year's last installment is still due).
    static func year(of job: Transaction) -> Int { Calendar.current.component(.year, from: job.date) }

    /// The share of Gross to set aside for a tax year (0 when there's nothing to estimate yet).
    static func rate(transactions: [Transaction], settings: FinanceSettings?, year: Int, now: Date = .now) -> Double {
        let report = ScheduleC.report(entries: transactions.map(\.ledgerEntry), year: year)
        // For a past year, project as of its end.
        let asOf = Calendar.current.component(.year, from: now) > year ? (Calendar.current.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? now) : now
        return EstimatedTax.plan(report: report, profile: settings?.taxProfile ?? TaxProfile(), paidFederal: 0, paidState: 0, reserve: 0, now: asOf).setAsideRate
    }
    static func isDecision(_ allocation: NetAllocation) -> Bool { allocation.kind == AllocationKinds.grossTax || allocation.kind == AllocationKinds.grossTaxSkipped }
    /// Every decision recorded for a job (more than one only if two devices decided before syncing).
    static func decisions(for job: Transaction, allocations: [NetAllocation]) -> [NetAllocation] {
        guard let id = job.jobID?.uuidString else { return [] }
        return allocations.filter { $0.target == id && isDecision($0) }
    }
    /// The decision that counts: a set-aside beats a "not now".
    static func decision(for job: Transaction, allocations: [NetAllocation]) -> NetAllocation? {
        let all = decisions(for: job, allocations: allocations)
        return all.first { $0.kind == AllocationKinds.grossTax } ?? all.first
    }
    /// Recent Gross payments, since the feature started, with no decision yet; newest first.
    static func pending(transactions: [Transaction], allocations: [NetAllocation], since: Date?, now: Date = .now) -> [Transaction] {
        let cutoff = max(Calendar.current.date(byAdding: .day, value: -offerDays, to: now) ?? .distantPast, since.map { Calendar.current.startOfDay(for: $0) } ?? .distantPast)
        let decided = Set(allocations.filter(isDecision).map(\.target))
        return transactions.filter { $0.isIncome && $0.incomeKind == "gross" && $0.amount > 0 && $0.date >= cutoff && $0.date < Calendar.current.endOfDay(for: now) && $0.jobID.map { !decided.contains($0.uuidString) } == true }
            .sorted { $0.date > $1.date }
    }
    /// Records the decision. The set-aside belongs to the month the job paid, so it covers that month's tax line.
    @MainActor static func record(_ job: Transaction, amount: Double, in context: ModelContext) {
        guard let id = job.jobID?.uuidString else { return }
        context.insert(NetAllocation(batchID: UUID(), date: .now, monthStart: Calendar.current.startOfMonth(for: job.date), target: id,
                                     kind: amount > 0 ? AllocationKinds.grossTax : AllocationKinds.grossTaxSkipped, amount: max(0, amount)))
        try? context.save()
    }
}

/// Today: "Riverside family paid $9,000. Set aside $2,551 for taxes?"
struct TaxSetAsideCard: View {
    @Environment(\.modelContext) private var context
    @Query private var allocations: [NetAllocation]
    @Query private var settingsList: [FinanceSettings]
    let transactions: [Transaction]

    var body: some View {
        let settings = FinanceSettings.pick(settingsList)
        let pending = JobTaxSetAside.pending(transactions: transactions, allocations: allocations, since: settings?.taxSetAsideSince)
        // The newest job whose tax year has something to estimate (a year with no profit yet has a 0% rate); "more"
        // counts only the others that would show an offer too.
        var rates: [Int: Double] = [:]
        let offerable = pending.compactMap { job -> (job: Transaction, rate: Double)? in
            let year = JobTaxSetAside.year(of: job)
            let rate = rates[year] ?? JobTaxSetAside.rate(transactions: transactions, settings: settings, year: year)
            rates[year] = rate
            return rate > 0 ? (job, rate) : nil
        }
        if let offer = offerable.first { card(offer.job, rate: offer.rate, more: offerable.count - 1) }
    }

    @ViewBuilder private func card(_ job: Transaction, rate: Double, more: Int) -> some View {
        let amount = TaxSetAside.amount(gross: job.amount, rate: rate)
        VStack(alignment: .leading, spacing: 10) {
                Label("\(job.title) paid \(job.amount.money)", systemImage: "percent").font(.headline)
                Text("Set aside \(amount.money) (\(rate.formatted(.percent.precision(.fractionLength(0))))) for \(String(JobTaxSetAside.year(of: job))) taxes? Move it to your tax savings, and Bedrock counts it in your tax reserve.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { setAsideButtons(job, amount: amount) }
                    VStack(alignment: .leading) { setAsideButtons(job, amount: amount) }
                }
                if more > 0 { Text("\(more) more in Plan › Income").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).marginCard()
    }

    @ViewBuilder private func setAsideButtons(_ job: Transaction, amount: Double) -> some View {
        Button("Set aside \(amount.money)") { JobTaxSetAside.record(job, amount: amount, in: context) }.buttonStyle(.borderedProminent).tint(.marginInk)
        Button("Not now") { JobTaxSetAside.record(job, amount: 0, in: context) }.buttonStyle(.bordered)
            .accessibilityLabel("Not now: don’t set aside tax for \(job.title)")
    }
}

/// Plan › Income job card: the set-aside for this job, or an offer to make one.
struct JobTaxSetAsideRow: View {
    @Environment(\.modelContext) private var context
    let job: Transaction
    /// This job's decisions and its year's set-aside rate, computed once by the list rather than per row.
    let decisions: [NetAllocation]; let rate: Double

    var body: some View {
        let decision = decisions.first { $0.kind == AllocationKinds.grossTax } ?? decisions.first
        if let decision, decision.kind == AllocationKinds.grossTax {
            HStack {
                Label("\(decision.amount.money) set aside for taxes", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(.green)
                Spacer()
                Button("Undo") { decisions.forEach(context.delete); try? context.save() }.font(.caption.bold()).tint(.marginCoral)
                    .accessibilityLabel("Undo the tax set-aside for \(job.title)")
            }
        } else if job.amount > 0, rate > 0 {
            let amount = TaxSetAside.amount(gross: job.amount, rate: rate)
            Button {
                decisions.forEach(context.delete)   // a "not now" is replaced by the set-aside
                JobTaxSetAside.record(job, amount: amount, in: context)
            } label: { Label("Set aside \(amount.money) for taxes", systemImage: "percent") }.font(.caption.bold()).tint(.marginInk)
        }
    }
}

// MARK: - Reminders

/// Schedules the reminders the person turned on as local notifications. Rebuilt from scratch each time (the app
/// calls this when it opens and closes), so they always reflect the latest numbers.
enum Reminders {
    static let prefix = "margin."

    @MainActor static func reschedule(context: ModelContext, now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard let settings = FinanceSettings.pick((try? context.fetch(FetchDescriptor<FinanceSettings>())) ?? []),
              settings.remindBills || settings.remindNet || settings.remindTaxes else { center.removePendingNotificationRequests(withIdentifiers: ours); return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { center.removePendingNotificationRequests(withIdentifiers: ours); return }

        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        let allocations = (try? context.fetch(FetchDescriptor<NetAllocation>())) ?? []
        let payments = (try? context.fetch(FetchDescriptor<EstimatedTaxPayment>())) ?? []
        let calendar = Calendar.current
        let month = transactions.filter { !$0.isIncome && $0.ledgerScope == "personal" && calendar.isSameMonth($0.date, now) }
        let bills = categories.compactMap { c -> (name: String, dueDay: Int, amount: Double, paidThisMonth: Bool)? in
            guard let day = c.dueDay, !c.isFund, c.name.caseInsensitiveCompare(settings.taxLineName) != .orderedSame else { return nil }
            return (c.name, day, c.monthlyLimit, month.filter { $0.category == c.name }.reduce(0) { $0 + $1.amount } > 0.005)
        }
        let year = EstimatedTax.plannerYear(now: now)
        let yearPayments = payments.filter { $0.taxYear == year }
        let plan = EstimatedTax.plan(report: ScheduleC.report(entries: transactions.map(\.ledgerEntry), year: year), profile: settings.taxProfile,
                                     paidFederal: yearPayments.filter { !$0.isState }.reduce(0) { $0 + $1.amount },
                                     paidState: yearPayments.filter(\.isState).reduce(0) { $0 + $1.amount }, reserve: 0, now: now)
        let taxDue = plan.next.map { (date: $0.dueDate, amount: plan.dueNextFederal + plan.dueNextState, quarter: $0.quarter) }
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let paidRecently = Set(transactions.filter { !$0.isIncome && $0.ledgerScope == "personal" && $0.amount > 0 && $0.date >= weekAgo && $0.date < calendar.endOfDay(for: now) }.map(\.category))
        let netArrived = transactions.filter { $0.isIncome && $0.incomeKind == "net" && $0.ledgerScope == "personal" && $0.date < calendar.endOfDay(for: now) }.map(\.date).max()
        let plans = ReminderSchedule.plan(bills: bills, paidRecently: paidRecently,
                                          leftToAssign: NetAssignment.leftToAssign(transactions: transactions, allocations: allocations, now: now), netArrived: netArrived,
                                          nextTaxDue: taxDue, includeBills: settings.remindBills, includeNet: settings.remindNet,
                                          includeTaxes: settings.remindTaxes, now: now)
        // Add (same id replaces) before removing what's no longer planned, so being suspended partway through never
        // leaves the person with no reminders.
        let keep = Array(plans.prefix(50))   // iOS keeps at most 64 pending per app
        for reminder in keep {
            let content = UNMutableNotificationContent(); content.title = reminder.title; content.body = reminder.body; content.sound = .default
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
            try? await center.add(UNNotificationRequest(identifier: prefix + reminder.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
        let planned = Set(keep.map { prefix + $0.id })
        center.removePendingNotificationRequests(withIdentifiers: ours.filter { !planned.contains($0) })
    }

    /// Asks for permission the first time a reminder is turned on. False if the person declined (now or before).
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }
}

/// Settings › Reminders.
struct RemindersSection: View {
    @Environment(\.modelContext) private var context
    @Bindable var settings: FinanceSettings
    @State private var denied = false

    var body: some View {
        Section {
            Toggle("Bills coming due", isOn: binding(\.remindBills))
            Toggle("Net waiting to be assigned", isOn: binding(\.remindNet))
            Toggle("Quarterly tax deadlines", isOn: binding(\.remindTaxes))
            if denied {
                Text("Notifications are off for Bedrock, so these reminders can’t arrive.").font(.caption).foregroundStyle(Color.marginCoral)
                Button("Turn on in Settings") { if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) } }
            }
        } header: { Text("Reminders") } footer: {
            Text("At 9 AM: two days before a bill is due, the morning after Net arrives if it’s still unassigned, and a week before an estimated-tax payment.")
        }
        .task {
            // Reflect a change made in the Settings app since the last visit.
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            denied = status == .denied && (settings.remindBills || settings.remindNet || settings.remindTaxes)
        }
    }

    private func binding(_ key: ReferenceWritableKeyPath<FinanceSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { on in
            settings[keyPath: key] = on; try? context.save()
            Task { @MainActor in
                if on, !(await Reminders.requestPermission()) { settings[keyPath: key] = false; try? context.save(); denied = true }
                await Reminders.reschedule(context: context)
            }
        })
    }
}
