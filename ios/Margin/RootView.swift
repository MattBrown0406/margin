import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var categories: [BudgetCategory]
    @Query private var goals: [SavingsGoal]
    @Query private var bookedJobs: [BookedJob]
    @AppStorage("margin.seeded") private var seeded = false
    @AppStorage("margin.ledgerV2Migrated") private var ledgerV2Migrated = false
    @State private var selectedTab = 0
    @State private var showAdd = false

    private var widgetSnapshot: WidgetSnapshot { WidgetSnapshot(entries: transactions.map(\.ledgerEntry), lines: categories.map(\.planLine), now: .now) }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { TodayView(transactions: transactions, categories: categories, goals: goals, bookedJobs: bookedJobs) }
                .tabItem { Label("Today", systemImage: "sun.max.fill") }.tag(0)
            NavigationStack { PlanView(transactions: transactions, categories: categories, bookedJobs: bookedJobs) }
                .tabItem { Label("Plan", systemImage: "chart.pie.fill") }.tag(1)
            Color.clear.tabItem { Label("Add", systemImage: "plus.circle.fill") }.tag(2)
            NavigationStack { ActivityView(transactions: transactions) }
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }.tag(3)
            NavigationStack { ReportsView(transactions: transactions, categories: categories) }
                .tabItem { Label("Reports", systemImage: "chart.bar.doc.horizontal.fill") }.tag(4)
        }
        .tint(.marginInk)
        .onChange(of: selectedTab) { previous, value in if value == 2 { showAdd = true; selectedTab = previous } }
        .sheet(isPresented: $showAdd) { AddEntryView(categories: categories, transactions: transactions) }
        .task { seedAndMigrateIfNeeded() }
        // iCloud can deliver another device's starter budget after this one seeded its own.
        .onChange(of: categories.count) { removeSyncDuplicates() }
        .onChange(of: goals.count) { removeSyncDuplicates() }
        // Keep the widget current whenever today's numbers change, and when returning to the app.
        .onChange(of: widgetSnapshot, initial: true) { _, snapshot in WidgetBridge.publish(snapshot) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { WidgetBridge.publish(widgetSnapshot) } }
    }

    private func seedAndMigrateIfNeeded() {
        if !ledgerV2Migrated {
            // Existing income is preserved as money received by the business. We do not
            // invent a personal transfer; the user records Net only when it really moves.
            transactions.filter { $0.isIncome && $0.incomeKind == nil }.forEach {
                $0.ledgerScope = "business"; $0.incomeKind = "gross"
                if $0.jobID == nil { $0.jobID = UUID() }
            }
            transactions.filter { !$0.isIncome && $0.ledgerScope.isEmpty }.forEach { $0.ledgerScope = "personal" }
            if let legacy = try? context.fetch(FetchDescriptor<Paycheck>()) { legacy.forEach { context.delete($0) } }
            ledgerV2Migrated = true
        }
        // Only a starter budget is seeded, never sample transactions: with iCloud sync, fake entries
        // from a new device would land in the real ledger on every other device.
        guard !seeded, categories.isEmpty else { seeded = true; try? context.save(); removeSyncDuplicates(); return }
        let targetDate = Calendar.current.date(byAdding: .month, value: 8, to: .now)
        let seedCategories = [
            BudgetCategory(name: "Giving", icon: "heart", monthlyLimit: 300, colorHex: "72BFA0", isFlexible: false, groupName: "Giving"),
            BudgetCategory(name: "Peace Number", icon: "shield.fill", monthlyLimit: 1050, colorHex: "72BFA0", isFlexible: false, groupName: "Saving & Funds", isFund: true, fundTarget: 25000, fundTargetDate: targetDate),
            BudgetCategory(name: "Car repairs", icon: "wrench.fill", monthlyLimit: 150, colorHex: "5F8FA3", isFlexible: false, groupName: "Saving & Funds", isFund: true, fundTarget: 1800, fundTargetDate: Calendar.current.date(byAdding: .month, value: 10, to: .now)),
            BudgetCategory(name: "Mortgage", icon: "house.fill", monthlyLimit: 2650, colorHex: "264653", isFlexible: false, groupName: "Housing", dueDay: 3),
            BudgetCategory(name: "Utilities", icon: "bolt.fill", monthlyLimit: 450, colorHex: "264653", isFlexible: false, groupName: "Housing", dueDay: 12),
            BudgetCategory(name: "Groceries", icon: "cart.fill", monthlyLimit: 700, colorHex: "E9C46A", groupName: "Food"),
            BudgetCategory(name: "Dining out", icon: "fork.knife", monthlyLimit: 200, colorHex: "E9C46A", groupName: "Food"),
            BudgetCategory(name: "Fuel", icon: "fuelpump.fill", monthlyLimit: 300, colorHex: "2A9D8F", groupName: "Transportation"),
            BudgetCategory(name: "Car insurance", icon: "car.fill", monthlyLimit: 250, colorHex: "2A9D8F", isFlexible: false, groupName: "Transportation", dueDay: 18),
            BudgetCategory(name: "Personal", icon: "person.fill", monthlyLimit: 350, colorHex: "F4A261", groupName: "Personal & Life"),
            BudgetCategory(name: "Fun money", icon: "sparkles", monthlyLimit: 300, colorHex: "E76F51", groupName: "Personal & Life"),
            BudgetCategory(name: "Health", icon: "cross.case.fill", monthlyLimit: 450, colorHex: "6D597A", isFlexible: false, groupName: "Personal & Life"),
            BudgetCategory(name: "Tax reserve", icon: "percent", monthlyLimit: 850, colorHex: "6D597A", isFlexible: false, groupName: "Taxes", dueDay: 25)
        ]
        seedCategories.forEach(context.insert)
        context.insert(SavingsGoal(name: "Peace Number", target: 25000, saved: 0, targetDate: Calendar.current.date(byAdding: .month, value: 12, to: .now) ?? .now, icon: "shield.fill"))
        seeded = true; ledgerV2Migrated = true
        try? context.save()
    }

    /// Keeps one record per name, choosing the oldest (ties broken by id) so every device keeps the same one.
    private func removeSyncDuplicates() {
        func survivorsFirst<T>(_ items: [T], createdAt: (T) -> Date, id: (T) -> UUID) -> [T] {
            items.sorted { (createdAt($0), id($0).uuidString) < (createdAt($1), id($1).uuidString) }
        }
        var changed = false
        for group in Dictionary(grouping: categories, by: { $0.name.lowercased() }).values where group.count > 1 {
            survivorsFirst(group, createdAt: \.createdAt, id: \.id).dropFirst().forEach { context.delete($0); changed = true }
        }
        for group in Dictionary(grouping: goals, by: { $0.name.lowercased() }).values where group.count > 1 {
            survivorsFirst(group, createdAt: \.createdAt, id: \.id).dropFirst().forEach { context.delete($0); changed = true }
        }
        if changed { try? context.save() }
    }
}

struct TodayView: View {
    let transactions: [Transaction]; let categories: [BudgetCategory]; let goals: [SavingsGoal]; let bookedJobs: [BookedJob]
    @State private var showAfford = false
    private var personalExpenses: [Transaction] { transactions.filter { !$0.isIncome && $0.ledgerScope == "personal" && Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) } }
    private var monthExpenses: Double { personalExpenses.reduce(0) { $0 + $1.amount } }
    private var safe: SafeToSpend { .compute(entries: transactions.map(\.ledgerEntry), lines: categories.map(\.planLine), now: .now) }
    private var shortfall: ForecastMonth? {
        CashFlowForecast.firstShortfall(CashFlowForecast.months(entries: transactions.map(\.ledgerEntry), booked: bookedJobs.filter(\.isOpen).map(\.info),
                                                                plannedMonthly: categories.reduce(0) { $0 + $1.monthlyLimit }, now: .now, count: 3))
    }
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) { case 5..<12: "Good morning"; case 12..<17: "Good afternoon"; default: "Good evening" }
    }

    var body: some View {
        let safe = safe
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) { Text("MARGIN").font(.caption.bold()).tracking(2); Text("\(greeting), Matt").font(.title2.bold()) }
                    Spacer()
                    NavigationLink { AccountView() } label: { Image(systemName: "gearshape").font(.title3).padding(10) }.tint(.marginInk).accessibilityLabel("Settings")
                    Image("MarginLogo")
                        .resizable().scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.8), lineWidth: 1))
                        .shadow(color: Color.marginInk.opacity(0.14), radius: 8, y: 4)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("SAFE TO SPEND TODAY").font(.caption.bold()).tracking(1.4).foregroundStyle(.white.opacity(0.65))
                    Text(safe.safeToday.money).font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(safe.spentToday > 0 ? "\(safe.spentToday.money) of today’s \(safe.dailyAllowance.money) already spent" : "from your personal plan — not business revenue").foregroundStyle(.white.opacity(0.75))
                    Divider().overlay(.white.opacity(0.2))
                    HStack { Label("\(safe.daysLeft) days left", systemImage: "calendar"); Spacer(); Text("\(safe.flexibleLeft.money) flexible") }.font(.subheadline).foregroundStyle(.white.opacity(0.85))
                }.padding(22).background(Color.marginInk, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                Button { showAfford = true } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "questionmark.bubble.fill").frame(width: 42, height: 42).background(Color.marginLime.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 3) { Text("Can I afford it?").font(.headline); Text("Check a purchase against your plan and booked work").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.marginCard()
                }.buttonStyle(.plain)
                if let shortfall {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.marginCoral)
                        Text("\(shortfall.monthStart.formatted(.dateTime.month(.wide))) is \((-shortfall.gap).money) short unless more work books for it.").font(.subheadline.bold())
                    }.frame(maxWidth: .infinity, alignment: .leading).marginCard()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Personal spending this month").font(.headline); Spacer(); Text(monthExpenses.money).bold() }
                    ProgressView(value: min(max(monthExpenses, 0) / max(1, categories.reduce(0) { $0 + $1.monthlyLimit }), 1)).tint(.marginLime).scaleEffect(y: 2)
                    Text("Business money stays separate until you record an actual Net transfer.").font(.subheadline).foregroundStyle(.secondary)
                }.marginCard()
                NavigationLink { BankAccountsView() } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "building.columns.fill").frame(width: 42, height: 42).background(Color.marginLime.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 3) { Text("Bank accounts").font(.headline); Text("Connect and review imported transactions").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.marginCard()
                }.buttonStyle(.plain)
                HStack { Text("Recent activity").font(.title3.bold()); Spacer(); NavigationLink("See all") { ActivityView(transactions: transactions) }.font(.subheadline.bold()) }
                if transactions.isEmpty { Text("Nothing recorded yet. Tap Add when you spend or when a job pays.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(transactions.prefix(4)) { TransactionRow(tx: $0) }
                if let goal = goals.first {
                    NavigationLink { GoalsView(goals: goals) } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(goal.name, systemImage: goal.icon).font(.headline)
                            HStack(alignment: .firstTextBaseline) { Text(goal.saved.money).font(.title.bold()); Text("of \(goal.target.money)").foregroundStyle(.secondary) }
                            ProgressView(value: goal.target > 0 ? min(goal.saved / goal.target, 1) : 1).tint(.marginMint)
                            Text(goal.saved >= goal.target ? "You’ve reached your \(goal.name)." : "You’re \((goal.target-goal.saved).money) away from your \(goal.name).").font(.subheadline).foregroundStyle(.secondary)
                        }.marginCard()
                    }.buttonStyle(.plain)
                }
            }.padding()
        }.background(Color.marginCream.ignoresSafeArea()).navigationBarHidden(true)
        .sheet(isPresented: $showAfford) { AffordView(transactions: transactions, categories: categories, bookedJobs: bookedJobs, goals: goals) }
    }
}

struct PlanView: View {
    let transactions: [Transaction]
    let categories: [BudgetCategory]
    let bookedJobs: [BookedJob]
    @State private var section = 0
    private var netIncome: Double { month.filter { $0.isIncome && $0.incomeKind == "net" && $0.ledgerScope == "personal" }.reduce(0) { $0 + $1.amount } }
    private var month: [Transaction] { transactions.filter { Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) } }
    private var planned: Double { categories.reduce(0) { $0 + $1.monthlyLimit } }
    private var groupNames: [String] { Array(Set(categories.map(\.groupName))).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Monthly plan").font(.largeTitle.bold())
                Picker("Plan section", selection: $section) { Text("Budget").tag(0); Text("Income").tag(1); Text("Bills").tag(2); Text("Forecast").tag(3) }.pickerStyle(.segmented)
                if section == 0 { budgetSection }
                if section == 1 { InterventionIncomeView(transactions: transactions) }
                if section == 2 { billsSection }
                if section == 3 { ForecastView(transactions: transactions, categories: categories, bookedJobs: bookedJobs) }
            }.padding()
        }.background(Color.marginCream.ignoresSafeArea()).navigationBarHidden(true)
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Only Net actually transferred into your personal account funds this plan.").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                PlanSummary(label: "NET INCOME", value: netIncome, dark: true)
                PlanSummary(label: "PLANNED", value: planned, dark: false)
                PlanSummary(label: "LEFT", value: netIncome - planned, dark: false)
            }
            ForEach(groupNames, id: \.self) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.uppercased()).font(.caption.bold()).tracking(1)
                    ForEach(categories.filter { $0.groupName == group }.sorted { $0.name < $1.name }) { BudgetLineRow(category: $0, transactions: transactions) }
                }
            }
        }
    }

    private var billsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upcoming personal bills").font(.title2.bold())
            Text("Due dates stay separate from everyday spending so nothing sneaks up on you.").foregroundStyle(.secondary)
            ForEach(categories.filter { $0.dueDay != nil }.sorted { ($0.dueDay ?? 0) < ($1.dueDay ?? 0) }) { bill in
                let paid = month.contains { !$0.isIncome && $0.ledgerScope == "personal" && $0.category == bill.name }
                HStack(spacing: 12) {
                    VStack { Text("DUE").font(.caption2.bold()); Text("\(bill.dueDay ?? 0)").font(.title3.bold()) }
                        .frame(width: 48, height: 48).background(paid ? Color.marginMint.opacity(0.35) : Color.marginInk, in: RoundedRectangle(cornerRadius: 13)).foregroundStyle(paid ? Color.marginInk : Color.white)
                    VStack(alignment: .leading) { Text(bill.name).bold(); Text(paid ? "Paid" : "Upcoming").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Text(bill.monthlyLimit.money).bold()
                }.marginCard()
            }
        }
    }
}

struct InterventionIncomeView: View {
    @Environment(\.modelContext) private var context
    let transactions: [Transaction]
    @State private var selectedGross: Transaction?
    private var month: [Transaction] { transactions.filter { Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) } }
    private func isThisMonth(_ date: Date) -> Bool { Calendar.current.isDate(date, equalTo: .now, toGranularity: .month) }
    /// This month's jobs, plus recent jobs still waiting on a personal transfer — otherwise a job paid
    /// late in a month vanishes on the 1st and its Net can never be recorded.
    private var recentGross: [Transaction] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        return transactions.filter { $0.isIncome && $0.incomeKind == "gross" && $0.date >= cutoff }.sorted { $0.date > $1.date }
    }
    private var grossEntries: [Transaction] { recentGross.filter { isThisMonth($0.date) || $0.netTransfers(in: transactions).isEmpty } }
    /// Older jobs that already have a transfer stay reachable so a later installment can be recorded.
    private var earlierEntries: [Transaction] { recentGross.filter { !isThisMonth($0.date) && !$0.netTransfers(in: transactions).isEmpty } }
    private var gross: Double { month.filter { $0.isIncome && $0.incomeKind == "gross" }.reduce(0) { $0 + $1.amount } }
    private var net: Double { month.filter { $0.isIncome && $0.incomeKind == "net" }.reduce(0) { $0 + $1.amount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Income is recorded when an intervention pays—not on a payroll schedule.").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                IncomeTotalCard(title: "GROSS", amount: gross, note: "Received by business", dark: true)
                IncomeTotalCard(title: "NET", amount: net, note: "Transferred personal", dark: false)
            }
            ForEach(grossEntries) { jobCard($0) }
            if grossEntries.isEmpty { ContentUnavailableView("No intervention income", systemImage: "briefcase", description: Text("Use Add to record money when a job pays.")) }
            if !earlierEntries.isEmpty {
                DisclosureGroup("Earlier jobs (\(earlierEntries.count))") { VStack(spacing: 12) { ForEach(earlierEntries) { jobCard($0) } }.padding(.top, 8) }.tint(.marginInk)
            }
        }.sheet(item: $selectedGross) { RecordNetTransferView(grossEntry: $0) }
    }

    private func jobCard(_ job: Transaction) -> some View {
        let transfers = job.netTransfers(in: transactions)
        return VStack(alignment: .leading, spacing: 10) {
            HStack { VStack(alignment: .leading) { Text(job.title).font(.headline); Text(job.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(job.amount.money).bold() }
            let spentOnJob = transactions.filter { !$0.isIncome && $0.ledgerScope == "business" && $0.jobID != nil && $0.jobID == job.jobID }.reduce(0) { $0 + $1.amount }
            if spentOnJob != 0 {
                HStack { Text("Job expenses \(spentOnJob.money)"); Spacer(); Text("Profit \((job.amount - spentOnJob).money)\(job.amount > 0 ? " · \(Int(((job.amount - spentOnJob) / job.amount * 100).rounded()))%" : "")").bold() }
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if !transfers.isEmpty {
                HStack { Label(transfers.count == 1 ? "Net transferred" : "Net transferred (\(transfers.count))", systemImage: "arrow.right.circle.fill"); Spacer(); Text(transfers.reduce(0) { $0 + $1.amount }.money).bold() }.foregroundStyle(.green)
                Button("Record another transfer") { selectedGross = job }.font(.caption.bold()).tint(.marginInk)
            } else {
                HStack { Text("No personal transfer recorded").font(.subheadline).foregroundStyle(.secondary); Spacer(); Button("Record Net") { selectedGross = job }.buttonStyle(.borderedProminent).tint(.marginInk) }
            }
        }.marginCard()
    }
}

struct IncomeTotalCard: View {
    let title: String; let amount: Double; let note: String; let dark: Bool
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.bold()).tracking(1); Text(amount.money).font(.title2.bold()); Text(note).font(.caption).opacity(0.75) }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(dark ? Color.marginInk : Color.marginMint, in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(dark ? Color.white : Color.marginInk) }
}

struct RecordNetTransferView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    let grossEntry: Transaction
    @State private var amount = ""; @State private var date = Date()
    var body: some View { NavigationStack { Form {
        Section("Intervention") { LabeledContent("Job", value: grossEntry.title); LabeledContent("Gross received", value: grossEntry.amount.money) }
        Section("Actual personal transfer") { TextField("Net amount", text: $amount).keyboardType(.decimalPad); DatePicker("Transfer date", selection: $date, displayedComponents: .date) }
        Section { Button("Record Net transfer") {
            guard let value = Double(moneyInput: amount) else { return }
            if grossEntry.jobID == nil { grossEntry.jobID = UUID() }
            context.insert(Transaction(title: grossEntry.title, amount: value, date: date, category: "Owner transfer", isIncome: true, ledgerScope: "personal", incomeKind: "net", jobID: grossEntry.jobID)); try? context.save(); dismiss()
        }.frame(maxWidth: .infinity).bold().disabled(Double(moneyInput: amount) == nil) }
    }.navigationTitle("Record Net").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }
}

struct PlanSummary: View {
    let label: String; let value: Double; let dark: Bool
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption2.bold()).opacity(0.65); Text(value.money).font(.headline.bold()) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(dark ? Color.marginInk : Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(dark ? Color.white : Color.marginInk) }
}

struct BudgetLineRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var category: BudgetCategory
    let transactions: [Transaction]
    @State private var editing = false
    private var spent: Double { transactions.filter { !$0.isIncome && $0.ledgerScope == "personal" && $0.category == category.name && Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) }.reduce(0) { $0 + $1.amount } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Label(category.name, systemImage: category.icon).font(.subheadline.bold()); Spacer(); Button(category.monthlyLimit.money) { editing = true }.buttonStyle(.bordered) }
            ProgressView(value: min(max(spent, 0) / max(category.monthlyLimit, 1), 1)).tint(spent > category.monthlyLimit ? .marginCoral : .marginMint)
            HStack { Text("Spent \(spent.money)"); Spacer(); Text("Remaining \((category.monthlyLimit-spent).money)") }.font(.caption).foregroundStyle(.secondary)
            if category.isFund { Label("Fund balance \(category.fundBalance.money) of \(category.fundTarget.money)", systemImage: "banknote.fill").font(.caption.bold()).foregroundStyle(.green) }
            if let day = category.dueDay { Text("Due on the \(day.ordinal)").font(.caption.bold()).foregroundStyle(.orange) }
        }.marginCard().sheet(isPresented: $editing) { NavigationStack { Form { TextField("Planned", value: $category.monthlyLimit, format: .number).keyboardType(.decimalPad) }.navigationTitle(category.name).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { try? context.save(); editing = false } } } } }
    }
}

extension Int { var ordinal: String { let formatter = NumberFormatter(); formatter.numberStyle = .ordinal; return formatter.string(from: NSNumber(value: self)) ?? "\(self)" } }

struct ActivityView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("margin.bankSkippedTransactionIDs") private var skippedJSON = "[]"
    let transactions: [Transaction]
    @State private var search = ""; @State private var scope = "all"
    var filtered: [Transaction] { transactions.filter { (scope == "all" || $0.ledgerScope == scope) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        List {
            Picker("Ledger", selection: $scope) { Text("All").tag("all"); Text("Personal").tag("personal"); Text("Business").tag("business") }.pickerStyle(.segmented).listRowBackground(Color.clear)
            ForEach(filtered) { TransactionRow(tx: $0).listRowBackground(Color.clear) }
                .onDelete(perform: delete)
        }.scrollContentBackground(.hidden).background(Color.marginCream).navigationTitle("Activity").searchable(text: $search, prompt: "Search entries")
    }
    /// Deleting a bank import also skips it, so the next sync doesn't offer it again.
    private func delete(at offsets: IndexSet) {
        let removed = offsets.map { filtered[$0] }
        var skipped = (try? JSONDecoder().decode([String].self, from: Data(skippedJSON.utf8))) ?? []
        skipped += removed.compactMap(\.externalID)
        if let data = try? JSONEncoder().encode(Array(Set(skipped)).sorted()), let value = String(data: data, encoding: .utf8) { skippedJSON = value }
        removed.forEach(context.delete); try? context.save()
    }
}

struct ReportsView: View {
    let transactions: [Transaction]; let categories: [BudgetCategory]
    @State private var scope = "all"; @State private var exportDocument: MarginXLSXDocument?; @State private var exporting = false
    private var month: [Transaction] { transactions.filter { Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) } }
    private var shown: [Transaction] { month.filter { scope == "all" || $0.ledgerScope == scope } }
    private var gross: Double { month.filter { $0.incomeKind == "gross" }.reduce(0) { $0 + $1.amount } }
    private var net: Double { month.filter { $0.incomeKind == "net" }.reduce(0) { $0 + $1.amount } }
    private var businessExpense: Double { month.filter { !$0.isIncome && $0.ledgerScope == "business" }.reduce(0) { $0 + $1.amount } }
    private var personalExpense: Double { month.filter { !$0.isIncome && $0.ledgerScope == "personal" }.reduce(0) { $0 + $1.amount } }
    private var year: Int { Calendar.current.component(.year, from: .now) }
    private var yearJobs: [JobSummary] {
        let calendar = Calendar.current
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: DateComponents(year: 1, second: -1), to: start) else { return [] }
        return JobProfit.summaries(entries: transactions.map(\.ledgerEntry), in: start...end)
    }
    private var scheduleC: ScheduleCReport { ScheduleC.report(entries: transactions.map(\.ledgerEntry), year: year) }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            Text("Reports").font(.largeTitle.bold())
            Text("Business and personal money stay visible without being mixed together.").foregroundStyle(.secondary)
            HStack(spacing: 10) { ReportMetric(label: "GROSS", value: gross); ReportMetric(label: "NET", value: net) }
            HStack(spacing: 10) { ReportMetric(label: "BUSINESS SPEND", value: businessExpense); ReportMetric(label: "PERSONAL SPEND", value: personalExpense) }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Retained in business", value: (gross - businessExpense - net).money)
                LabeledContent("Personal margin", value: (net - personalExpense).money)
            }.font(.headline).marginCard()
            JobProfitCard(year: year, jobs: yearJobs, scheduleC: scheduleC)
            Picker("Ledger", selection: $scope) { Text("All").tag("all"); Text("Personal").tag("personal"); Text("Business").tag("business") }.pickerStyle(.segmented)
            ForEach(shown) { TransactionRow(tx: $0) }
            Button { exportDocument = MarginXLSXDocument(transactions: transactions, categories: categories); exporting = true } label: { Label("Export Excel (.xlsx)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(5) }.buttonStyle(.borderedProminent).tint(.marginInk)
            Text("Exports Summary, Income & Jobs, Expenses, Budget, and Category Totals for this month, plus Job Profit and a Schedule C summary for the year.").font(.caption).foregroundStyle(.secondary)
        }.padding() }.background(Color.marginCream.ignoresSafeArea()).navigationBarHidden(true)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: MarginXLSXDocument.contentType, defaultFilename: "Margin-Monthly-Report") { _ in }
    }
}

/// This year's per-job economics and a Schedule C preview.
struct JobProfitCard: View {
    let year: Int; let jobs: [JobSummary]; let scheduleC: ScheduleCReport
    var body: some View {
        let totals = JobProfit.totals(jobs)
        VStack(alignment: .leading, spacing: 10) {
            Text("Job profit · \(String(year))").font(.headline)
            if jobs.isEmpty {
                Text("When a job pays, tag its business expenses to it (Add › Business › For job) to see what each one really earned.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack { ReportMetric(label: "AVG PROFIT / JOB", value: totals.averageProfit); ReportMetric(label: "JOB EXPENSES", value: totals.expenses) }
                if let best = totals.best { Text("Most profitable: \(best.title), \(best.profit.money)\(best.margin.map { " (\(Int(($0 * 100).rounded()))%)" } ?? "")").font(.subheadline) }
                ForEach(jobs.prefix(5)) { job in
                    HStack { VStack(alignment: .leading) { Text(job.title).font(.subheadline.bold()); Text(job.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); VStack(alignment: .trailing) { Text(job.profit.money).font(.subheadline.bold()); Text("of \(job.gross.money)").font(.caption).foregroundStyle(.secondary) } }
                }
            }
            Divider()
            LabeledContent("Schedule C net profit (YTD)", value: scheduleC.netProfit.money).font(.subheadline.bold())
            Text("Gross receipts \(scheduleC.grossReceipts.money) minus \(scheduleC.totalExpenses.money) deductible business expenses. A starting point for your tax preparer, not tax advice.").font(.caption).foregroundStyle(.secondary)
        }.marginCard()
    }
}

struct ReportMetric: View { let label: String; let value: Double; var body: some View { VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption2.bold()).foregroundStyle(.secondary); Text(value.money).font(.title3.bold()) }.frame(maxWidth: .infinity, alignment: .leading).marginCard() } }

struct GoalsView: View {
    let goals: [SavingsGoal]
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        Text("Goals").font(.largeTitle.bold()); Text("Savings is a promise to your future self.").foregroundStyle(.secondary)
        ForEach(goals) { goal in VStack(alignment: .leading, spacing: 14) { Image(systemName: goal.icon).font(.title).foregroundStyle(Color.marginInk); Text(goal.name).font(.title2.bold()); Text("\(goal.saved.money) saved of \(goal.target.money)"); ProgressView(value: goal.target > 0 ? min(goal.saved/goal.target, 1) : 1).tint(.marginLime).scaleEffect(y: 2); Text("\(goal.target > 0 ? Int(goal.saved/goal.target*100) : 100)% complete").font(.caption.bold()).foregroundStyle(.secondary) }.marginCard() }
    }.padding() }.background(Color.marginCream.ignoresSafeArea()).navigationBarHidden(true) }
}

struct TransactionRow: View {
    let tx: Transaction
    /// Refunds are stored as negative expenses and shown as money coming back.
    private var amountPrefix: String { tx.isIncome || tx.amount < 0 ? "+" : "−" }
    private var detail: String { "\(tx.ledgerScope.capitalized) · \(tx.incomeKind?.capitalized ?? (tx.amount < 0 ? "Refund · \(tx.category)" : tx.category))" }
    var body: some View { HStack(spacing: 13) {
        Image(systemName: tx.isIncome ? "arrow.down.left" : "arrow.up.right").frame(width: 38, height: 38).background(tx.isIncome ? Color.marginLime.opacity(0.55) : Color.black.opacity(0.05), in: Circle())
        VStack(alignment: .leading) { Text(tx.title).font(.subheadline.bold()); Text(detail).font(.caption).foregroundStyle(.secondary) }
        Spacer(); Text(amountPrefix + abs(tx.amount).moneyExact).font(.subheadline.bold()).foregroundStyle(tx.isIncome ? .green : .primary)
    }.padding(.vertical, 5) }
}

struct AddEntryView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    let categories: [BudgetCategory]
    let transactions: [Transaction]
    @State private var type = 0
    @State private var jobID: UUID?
    @State private var title = ""; @State private var amount = ""; @State private var date = Date(); @State private var category = ""; @State private var essential = true; @State private var scope = "personal"
    @State private var gross = ""; @State private var grossDate = Date(); @State private var net = ""; @State private var netDate = Date()
    private var personalCategoryNames: [String] { categories.sorted { ($0.groupName, $0.name) < ($1.groupName, $1.name) }.map(\.name) }
    private var categoryOptions: [String] { scope == "business" ? businessCategoryNames : personalCategoryNames }
    /// Recent jobs a business expense can be charged to, for per-job profit.
    private var recentJobs: [Transaction] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: .now) ?? .distantPast
        return transactions.filter { $0.isIncome && $0.incomeKind == "gross" && $0.jobID != nil && $0.date >= cutoff }.sorted { $0.date > $1.date }
    }
    private var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A typed Net that can't be parsed must block saving rather than be silently dropped.
    private var netIsValid: Bool { net.trimmingCharacters(in: .whitespaces).isEmpty || Double(moneyInput: net) != nil }
    private var canSave: Bool { hasTitle && (type == 0 ? Double(moneyInput: amount) != nil && categoryOptions.contains(category) : Double(moneyInput: gross) != nil && netIsValid) }
    var body: some View { NavigationStack { Form {
        Picker("Type", selection: $type) { Text("Expense").tag(0); Text("Intervention income").tag(1) }.pickerStyle(.segmented)
        if type == 0 {
            Section("Expense") { TextField("Merchant or description", text: $title); TextField("Amount", text: $amount).keyboardType(.decimalPad); DatePicker("Date", selection: $date, displayedComponents: .date) }
            Section("Ledger") {
                Picker("Account", selection: $scope) { Text("Personal").tag("personal"); Text("Business").tag("business") }.pickerStyle(.segmented)
                Picker("Category", selection: $category) { ForEach(categoryOptions, id: \.self) { Text($0).tag($0) } }
                if scope == "personal" { Toggle("This was necessary", isOn: $essential) }
                if scope == "business", !recentJobs.isEmpty {
                    Picker("For job", selection: $jobID) {
                        Text("Not tied to a job").tag(UUID?.none)
                        ForEach(recentJobs) { job in Text("\(job.title) · \(job.date.formatted(date: .abbreviated, time: .omitted))").tag(job.jobID) }
                    }
                }
            }
        } else {
            Section("Job") { TextField("Intervention or job name", text: $title); TextField("Gross received by business", text: $gross).keyboardType(.decimalPad); DatePicker("Date received", selection: $grossDate, displayedComponents: .date) }
            Section("Net transfer — optional") { Text("Leave this blank if the money has not moved into your personal account yet.").font(.caption).foregroundStyle(.secondary); TextField("Amount transferred personal", text: $net).keyboardType(.decimalPad); DatePicker("Transfer date", selection: $netDate, displayedComponents: .date) }
        }
        Section { Button("Save entry") { saveEntry() }.frame(maxWidth: .infinity).bold().disabled(!canSave) }
    }.navigationTitle(type == 0 ? "Add expense" : "Log intervention income").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear(perform: resetCategoryIfNeeded).onChange(of: scope) { resetCategoryIfNeeded() }
    } }
    /// Keeps the category valid for the chosen ledger, so a business expense can't be saved as "Groceries".
    private func resetCategoryIfNeeded() { if !categoryOptions.contains(category) { category = categoryOptions.first ?? "" } }
    private func saveEntry() {
        guard canSave else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == 0, let value = Double(moneyInput: amount) {
            context.insert(Transaction(title: name, amount: value, date: date, category: category, isEssential: scope == "personal" ? essential : true, ledgerScope: scope, jobID: scope == "business" ? jobID : nil))
        } else if let grossValue = Double(moneyInput: gross) {
            let jobID = UUID()
            context.insert(Transaction(title: name, amount: grossValue, date: grossDate, category: "Intervention income", isIncome: true, ledgerScope: "business", incomeKind: "gross", jobID: jobID))
            if let netValue = Double(moneyInput: net) { context.insert(Transaction(title: name, amount: netValue, date: netDate, category: "Owner transfer", isIncome: true, ledgerScope: "personal", incomeKind: "net", jobID: jobID)) }
        }
        try? context.save(); dismiss()
    }
}
