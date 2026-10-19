import SwiftUI
import SwiftData

/// Numbers several money tools share, computed the same way everywhere.
struct MoneyFacts {
    let entries: [LedgerEntry]
    let lines: [PlanLine]
    /// The whole monthly plan.
    let planned: Double
    /// What a typical month's plan needs from Net: for someone who sets tax aside from Gross, the tax line is
    /// funded that way instead.
    let plannedFromNet: Double
    /// This month's plan less only the tax already set aside from Gross (not tax expected from jobs yet to pay).
    let plannedFromNetThisMonth: Double
    let forecast: [ForecastMonth]
    /// The earliest booked job still expected to pay after `now`.
    let nextIncome: Date?

    init(transactions: [Transaction], categories: [BudgetCategory], bookedJobs: [BookedJob], allocations: [NetAllocation], settings: FinanceSettings?,
         now: Date = .now, months: Int = 6) {
        let calendar = Calendar.current
        entries = transactions.map(\.ledgerEntry)
        lines = categories.map(\.planLine)
        planned = categories.reduce(0) { $0 + $1.monthlyLimit }
        let taxLineName = settings?.taxLineName ?? "Tax reserve"
        let taxLine = categories.filter { $0.name.caseInsensitiveCompare(taxLineName) == .orderedSame }.reduce(0) { $0 + $1.monthlyLimit }
        let setAsides = allocations.filter { $0.kind == AllocationKinds.grossTax && $0.amount > 0 }
        // Counted the way Assign Net counts them: once, in the later of the job's month and the month it was made.
        let byMonth = Dictionary(setAsides.map { (max($0.monthKey, calendar.monthKey(for: $0.date)), $0.amount) }, uniquingKeysWith: +)
        // Bookings are expected to have tax set aside too only for someone who has done so in the last year.
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        let setsAside = setAsides.contains { $0.date >= yearAgo }
        let rate = setsAside ? JobTaxSetAside.rate(transactions: transactions, settings: settings, year: calendar.component(.year, from: now), now: now) : 0
        // A typical month's set-aside: the rate applied to the last year's average monthly Gross.
        let yearGrosses = entries.filter { $0.isGross && $0.date >= yearAgo && $0.date < calendar.endOfDay(for: now) }
        // Averaged over the months actually covered (bank history may only reach back a few months), at most 12.
        let months = yearGrosses.map(\.date).min().map { min(12, max(1, calendar.monthsBetween($0, now) + 1)) } ?? 12
        plannedFromNet = max(0, planned - min(taxLine, rate * yearGrosses.total / Double(months)))
        plannedFromNetThisMonth = max(0, planned - min(taxLine, byMonth[calendar.monthKey(for: now)] ?? 0))
        let expected = BookedJob.expectedIncome(bookedJobs, entries: entries)
        forecast = CashFlowForecast.months(entries: entries, booked: expected, plannedMonthly: planned, now: now, count: months,
                                           carriedIn: NetAssignment.carriedIn(transactions: transactions, allocations: allocations, now: now),
                                           taxLine: taxLine, setAsideByMonth: byMonth, setAsideRate: rate)
        nextIncome = expected.map(\.expectedDate).filter { $0 > now }.min()
    }
}

/// A Double typed as money. Blank or unparseable text leaves the value unchanged until it is valid.
struct MoneyField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...2))).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Today entry points

/// The four planning tools, reachable from Today.
struct MoneyToolsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Money tools").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                tool("Steady paycheck", "calendar.badge.clock") { SteadyPaycheckView() }
                tool("Taxes", "percent") { TaxPlannerView() }
                tool("Debt payoff", "creditcard.fill") { DebtPayoffView() }
                tool("Net worth", "chart.line.uptrend.xyaxis") { NetWorthView() }
            }
        }.marginCard()
    }
    private func tool<Destination: View>(_ title: String, _ icon: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 8) { Image(systemName: icon).frame(width: 22); Text(title).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.8); Spacer(minLength: 0) }
                .padding(12).frame(maxWidth: .infinity).background(Color.marginLime.opacity(0.35), in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain)
    }
}

/// "You have $X of Net to assign" on Today, when this month's Net isn't all assigned.
struct LeftToAssignCard: View {
    @Query private var allocations: [NetAllocation]
    let transactions: [Transaction]

    var body: some View {
        let left = NetAssignment.leftToAssign(transactions: transactions, allocations: allocations)
        if left > 0.5 {
            NavigationLink { AssignNetView() } label: {
                HStack(spacing: 13) {
                    Image(systemName: "tray.and.arrow.down.fill").frame(width: 42, height: 42).background(Color.marginLime.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) { Text("\(left.money) of Net to assign").font(.headline); Text("Give every dollar a job: bills first, then taxes and funds").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.marginCard()
            }.buttonStyle(.plain)
        }
    }
}

enum NetAssignment {
    /// Allocation kinds that come out of this month's Net (a rollover or a set-aside from Gross doesn't).
    static func isFromNet(_ kind: String) -> Bool { AllocationKinds.isFromNet(kind) }

    static func monthNet(_ transactions: [Transaction], now: Date = .now) -> Double {
        transactions.filter { $0.isIncome && $0.incomeKind == "net" && $0.ledgerScope == "personal" && Calendar.current.isDate($0.date, equalTo: now, toGranularity: .month) }.reduce(0) { $0 + $1.amount }
    }
    static func assignedThisMonth(_ allocations: [NetAllocation], now: Date = .now) -> [NetAllocation] {
        let key = Calendar.current.monthKey(for: now)
        return allocations.filter { isFromNet($0.kind) && $0.monthKey == key }
    }
    /// Net that arrived in the last days of last month and wasn't assigned there: it usually pays this month's
    /// first bills, so it can be assigned now. Bounded to those last five days, so an unused feature doesn't pile up.
    static let lateNetDays = 5
    static func carriedIn(transactions: [Transaction], allocations: [NetAllocation], now: Date = .now) -> Double {
        carriedIn(nets: personalNets(transactions), allocations: allocations, now: now)
    }
    /// Personal Net transfers as (date, amount), so a "what if" edit can be worked out with the same rules.
    static func personalNets(_ transactions: [Transaction]) -> [(date: Date, amount: Double)] {
        transactions.filter { $0.isIncome && $0.incomeKind == "net" && $0.ledgerScope == "personal" }.map { ($0.date, $0.amount) }
    }
    static func carriedIn(nets all: [(date: Date, amount: Double)], allocations: [NetAllocation], now: Date = .now) -> Double {
        let calendar = Calendar.current, thisMonth = calendar.startOfMonth(for: now)
        guard let previous = calendar.date(byAdding: .month, value: -1, to: thisMonth),
              let lateStart = calendar.date(byAdding: .day, value: -lateNetDays, to: thisMonth) else { return 0 }
        let nets = all.filter { $0.date >= previous && $0.date < thisMonth }
        let late = nets.filter { $0.date >= lateStart }.reduce(0) { $0 + $1.amount }
        let previousKey = calendar.monthKey(for: previous)
        let assigned = allocations.filter { isFromNet($0.kind) && $0.monthKey == previousKey }.reduce(0) { $0 + $1.amount }
        return max(0, min(late, nets.reduce(0) { $0 + $1.amount } - assigned))
    }
    static func leftToAssign(transactions: [Transaction], allocations: [NetAllocation], now: Date = .now) -> Double {
        max(0, monthNet(transactions, now: now) + carriedIn(transactions: transactions, allocations: allocations, now: now)
            - assignedThisMonth(allocations, now: now).reduce(0) { $0 + $1.amount })
    }
}

/// At the start of a month: move last month's unspent flexible money into a fund.
struct RolloverCard: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FinanceSettings]
    @Query private var goals: [SavingsGoal]
    @Query private var allocations: [NetAllocation]
    let transactions: [Transaction]; let categories: [BudgetCategory]
    @State private var fundName = ""

    private var previousMonth: Date { Calendar.current.date(byAdding: .month, value: -1, to: Calendar.current.startOfMonth(for: .now)) ?? .now }
    private var previousKey: String { Calendar.current.monthKey(for: previousMonth) }
    /// Unspent flexible money last month, but never more than really stayed free: Net, minus spending, minus Net already
    /// given to funds, taxes, or extra (those create no transactions, but the money is spoken for).
    private var leftover: Double {
        let prev = transactions.filter { Calendar.current.isSameMonth($0.date, previousMonth) }
        guard !prev.isEmpty else { return 0 }
        let flexibleNames = Set(categories.filter(\.isFlexible).map(\.name))
        let personalSpend = prev.filter { !$0.isIncome && $0.ledgerScope == "personal" }.reduce(0) { $0 + $1.amount }
        let flexibleSpend = prev.filter { !$0.isIncome && $0.ledgerScope == "personal" && flexibleNames.contains($0.category) }.reduce(0) { $0 + $1.amount }
        let net = prev.filter { $0.isIncome && $0.incomeKind == "net" }.reduce(0) { $0 + $1.amount }
        let flexibleLeft = categories.filter(\.isFlexible).reduce(0) { $0 + $1.monthlyLimit } - flexibleSpend
        let spokenFor: Set<String> = [AllocationTarget.Kind.fund.rawValue, AllocationTarget.Kind.tax.rawValue, AllocationTarget.Kind.extra.rawValue]
        let setAside = allocations.filter { $0.monthKey == previousKey && spokenFor.contains($0.kind) }.reduce(0) { $0 + $1.amount }
        // A rollover already made for that month (perhaps on another device whose settings haven't synced yet).
        let rolled = allocations.filter { $0.monthKey == previousKey && $0.kind == "rollover" }.reduce(0) { $0 + $1.amount }
        // Late Net from last month can be assigned this month instead, so it isn't leftover to roll.
        let carried = NetAssignment.carriedIn(transactions: transactions, allocations: allocations)
        return ((min(flexibleLeft, net - personalSpend - setAside - carried) - rolled) * 100).rounded(.down) / 100
    }
    private var funds: [String] { categories.filter(\.isFund).map(\.name).sorted() }

    var body: some View {
        let settings = FinanceSettings.pick(settingsList), amount = leftover
        if let settings, amount >= 1, !funds.isEmpty, settings.lastRolloverMonthKey < previousKey {
            VStack(alignment: .leading, spacing: 10) {
                Label("\(previousMonth.formatted(.dateTime.month(.wide))) left \(amount.money) unspent", systemImage: "arrow.uturn.right.circle.fill").font(.headline)
                // Always a real fund (the state starts empty until onAppear picks one).
                Picker("Move it to", selection: Binding(get: { funds.contains(fundName) ? fundName : (funds.contains(settings.surplusTarget) ? settings.surplusTarget : funds[0]) }, set: { fundName = $0 })) {
                    ForEach(funds, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Button("Move \(amount.money)") {
                        let target = funds.contains(fundName) ? fundName : funds[0]
                        addToFundOrGoal(target, amount: amount, categories: categories, goals: goals)
                        context.insert(NetAllocation(batchID: UUID(), date: .now, monthStart: previousMonth, target: target, kind: "rollover", amount: amount))
                        settings.lastRolloverMonthKey = previousKey; try? context.save()
                    }.buttonStyle(.borderedProminent).tint(.marginInk)
                    Button("Not now") { settings.lastRolloverMonthKey = previousKey; try? context.save() }.buttonStyle(.bordered)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).marginCard()
            .onAppear { if !funds.contains(fundName) { fundName = funds.contains(settings.surplusTarget) ? settings.surplusTarget : funds[0] } }
        }
    }
}

// MARK: - Assign Net

struct AssignNetView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var categories: [BudgetCategory]
    @Query private var goals: [SavingsGoal]
    @Query private var bookedJobs: [BookedJob]
    @Query(sort: \NetAllocation.date, order: .reverse) private var allocations: [NetAllocation]
    @Query private var settingsList: [FinanceSettings]
    /// Amounts the person typed over the suggestion, by line id.
    @State private var overrides: [String: String] = [:]

    private var settings: FinanceSettings? { FinanceSettings.pick(settingsList) }
    private var monthStart: Date { Calendar.current.startOfMonth(for: .now) }
    private var thisMonth: [NetAllocation] { NetAssignment.assignedThisMonth(allocations) }
    private var left: Double { NetAssignment.leftToAssign(transactions: transactions, allocations: allocations) }
    private var surplusOptions: [String] { Array(Set(categories.filter(\.isFund).map(\.name) + goals.map(\.name))).sorted() }

    private var suggestions: [AllocationLine] {
        var assigned = Dictionary(thisMonth.filter { $0.kind != AllocationTarget.Kind.extra.rawValue }.map { ($0.target, $0.amount) }, uniquingKeysWith: +)
        // Tax set aside from this month's job payments already covers that much of the month's tax line.
        let key = Calendar.current.monthKey(for: .now), taxLineSetting = settings?.taxLineName ?? "Tax reserve"
        // The plan line's own spelling, so a "Tax Reserve" line still matches a "Tax reserve" setting.
        let taxLine = categories.first { $0.name.caseInsensitiveCompare(taxLineSetting) == .orderedSame }?.name ?? taxLineSetting
        // Each counts once, in the later of its job's month and the month it was made (Net usually lags its job's Gross).
        assigned[taxLine, default: 0] += allocations.filter { $0.kind == AllocationKinds.grossTax && max($0.monthKey, Calendar.current.monthKey(for: $0.date)) == key }.reduce(0) { $0 + $1.amount }
        let spent = Dictionary(transactions.filter { !$0.isIncome && $0.ledgerScope == "personal" && Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) }
            .map { ($0.category, $0.amount) }, uniquingKeysWith: +)
        let targets = NetAllocator.targets(lines: categories.map(\.planLine), taxLineName: settings?.taxLineName ?? "Tax reserve", assigned: assigned, spent: spent)
        let facts = MoneyFacts(transactions: transactions, categories: categories, bookedJobs: bookedJobs, allocations: allocations, settings: settings)
        let surplus = settings.map(\.surplusTarget).flatMap { surplusOptions.contains($0) ? $0 : nil }
        return NetAllocator.suggest(amount: left, targets: targets, now: .now, nextIncome: facts.nextIncome, surplusTarget: surplus)
    }
    /// Blank means 0; anything else must be a valid amount.
    private func amount(for line: AllocationLine) -> Double? {
        guard let text = overrides[line.id] else { return line.amount }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || Double(trimmed) == 0 { return 0 }
        return Double(moneyInput: trimmed)
    }

    var body: some View {
        let lines = suggestions, chosen = lines.map(amount(for:)), total = chosen.compactMap { $0 }.reduce(0, +)
        let valid = !chosen.contains(nil) && total > 0.005 && total <= left + 0.005
        Form {
            Section {
                LabeledContent("Net received this month", value: NetAssignment.monthNet(transactions).money)
                let carried = NetAssignment.carriedIn(transactions: transactions, allocations: allocations)
                if carried > 0.005 { LabeledContent("Late last month, not yet assigned", value: carried.money) }
                LabeledContent("Already assigned", value: thisMonth.reduce(0) { $0 + $1.amount }.money)
                LabeledContent("Left to assign", value: left.money).bold()
            } footer: { Text("Assigning doesn’t move money. It decides what this month’s Net is for, so bills and taxes are covered before it gets spent.") }

            if left <= 0.005 {
                Section { Label("Every dollar of this month’s Net has a job.", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            } else if lines.isEmpty {
                Section { Text("Your plan is fully covered this month. Choose a fund below for anything extra.").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(line.kind == .extra ? "Extra → \(line.name)" : line.name).font(.subheadline.bold())
                                Spacer()
                                TextField("0", text: Binding(get: { overrides[line.id] ?? String(format: "%.2f", line.amount) }, set: { overrides[line.id] = $0 }))
                                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
                            }
                            Text(line.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Total", value: total.moneyExact)
                    if total > left + 0.005 { Text("That’s more than the \(left.moneyExact) left to assign.").font(.caption).foregroundStyle(.red) }
                    Button("Assign \(total.money)") { assign(lines, amounts: chosen.map { $0 ?? 0 }) }.bold().frame(maxWidth: .infinity).disabled(!valid)
                } header: { Text("Suggested") } footer: { Text("Bills due before your next expected job come first, then taxes, then funds, then the rest of the plan.") }
            }

            if let settings {
                Section {
                    Picker("Once the plan is covered", selection: Binding(get: { settings.surplusTarget }, set: { settings.surplusTarget = $0; try? context.save(); overrides = [:] })) {
                        Text("Leave it unassigned").tag("")
                        ForEach(surplusOptions, id: \.self) { Text($0).tag($0) }
                    }
                } footer: { Text("Extra Net goes here after every plan line is covered.") }
            }

            let batches = Dictionary(grouping: thisMonth, by: \.batchID).sorted { ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast) }
            if !batches.isEmpty {
                Section("Assigned this month") {
                    ForEach(batches, id: \.key) { batch in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(batch.value.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "").font(.subheadline.bold()); Spacer(); Text(batch.value.reduce(0) { $0 + $1.amount }.money).bold() }
                            Text(batch.value.sorted { $0.amount > $1.amount }.map { "\($0.target) \($0.amount.money)" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            Button("Undo", role: .destructive) { undo(batch.value) }.font(.caption.bold())
                        }
                    }
                }
            }
        }
        .numberPadDone().navigationTitle("Assign Net")
        .task { _ = FinanceSettings.current(in: context) }
    }

    private func assign(_ lines: [AllocationLine], amounts: [Double]) {
        let batch = UUID()
        for (line, value) in zip(lines, amounts) where value > 0.005 {
            let cents = (value * 100).rounded() / 100
            context.insert(NetAllocation(batchID: batch, date: .now, monthStart: monthStart, target: line.name, kind: line.kind.rawValue, amount: cents))
            switch line.kind {
            case .fund, .extra: addToFundOrGoal(line.name, amount: cents, categories: categories, goals: goals)
            default: break   // the tax reserve is worked out from these records
            }
        }
        overrides = [:]
        try? context.save()
    }

    private func undo(_ batch: [NetAllocation]) {
        for allocation in batch {
            switch AllocationTarget.Kind(rawValue: allocation.kind) {
            case .fund, .extra: addToFundOrGoal(allocation.target, amount: -allocation.amount, categories: categories, goals: goals)
            default: break
            }
            context.delete(allocation)
        }
        overrides = [:]
        try? context.save()
    }
}

// MARK: - Steady paycheck

struct SteadyPaycheckView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var categories: [BudgetCategory]
    @Query private var bookedJobs: [BookedJob]
    @Query private var settingsList: [FinanceSettings]
    @Query private var allocations: [NetAllocation]

    var body: some View {
        Form {
            if let settings = FinanceSettings.pick(settingsList) { SteadyPaycheckForm(settings: settings, facts: MoneyFacts(transactions: transactions, categories: categories, bookedJobs: bookedJobs, allocations: allocations, settings: settings)) }
        }
        .numberPadDone().navigationTitle("Steady paycheck")
        .task { _ = FinanceSettings.current(in: context) }
    }
}

private struct SteadyPaycheckForm: View {
    @Environment(\.modelContext) private var context
    @Bindable var settings: FinanceSettings
    let facts: MoneyFacts

    var body: some View {
        let plan = SteadyPaycheck.plan(entries: facts.entries, chosenPaycheck: settings.monthlyPaycheck, buffer: settings.incomeBuffer, plannedMonthly: facts.plannedFromNet, forecast: facts.forecast, now: .now)
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR MONTHLY PAYCHECK").font(.caption.bold()).foregroundStyle(.secondary)
                Text(plan.paycheck.money).font(.system(size: 40, weight: .bold, design: .rounded))
                Text(plan.monthsOfHistory == 0 ? "Record a few months of Net transfers and Bedrock will suggest an amount."
                     : "Your Net averaged \(plan.averageMonthlyNet.money) a month over the last \(plan.monthsOfHistory) month\(plan.monthsOfHistory == 1 ? "" : "s") (lowest \(plan.lowestMonthNet.money)).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
            if plan.monthsOfHistory > 0, plan.monthsOfHistory < 3 { Label("Based on little history; treat it as a starting point.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
        }
        Section {
            LabeledContent("Suggested", value: plan.suggestedPaycheck.money)
            MoneyField(title: "My paycheck", value: $settings.monthlyPaycheck)
            LabeledContent("Monthly plan", value: plan.plannedMonthly.money)
            Label(plan.coversPlan ? "This paycheck covers your plan." : "Your plan needs \((plan.plannedMonthly - plan.paycheck).money) more a month than this paycheck. Trim the plan or raise the paycheck if the buffer allows.",
                  systemImage: plan.coversPlan ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(plan.coversPlan ? Color.green : Color.marginCoral)
        } header: { Text("Paycheck") } footer: { Text("Set 0 to use the suggestion: your average monthly Net over the last year, rounded down to $50.") }
        Section {
            MoneyField(title: "In the buffer today", value: $settings.incomeBuffer)
            if let runway = plan.runwayMonths { LabeledContent("Runway with no new work", value: "\(runway.formatted(.number.precision(.fractionLength(1)))) months") }
        } header: { Text("Income buffer") } footer: { Text("The savings account every Net transfer lands in. Update it when you check your balance.") }
        if !plan.projection.isEmpty {
            Section {
                ForEach(plan.projection) { month in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(month.monthStart.formatted(.dateTime.month(.wide).year())).font(.subheadline.bold())
                            Text(month.paycheckOut == 0 ? "+\(month.expectedIn.money) booked (paycheck already taken)" : "+\(month.expectedIn.money) booked − \(month.paycheckOut.money) paycheck").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Text(month.endBalance.money).bold().foregroundStyle(month.endBalance < 0 ? Color.marginCoral : .primary)
                    }
                }
                if let empty = plan.firstEmptyMonth { Text("On booked work alone, the buffer runs out in \(empty.formatted(.dateTime.month(.wide).year())).").font(.subheadline.bold()).foregroundStyle(Color.marginCoral) }
            } header: { Text("Buffer, month by month") } footer: { Text("Counts only jobs you’ve booked, so it shows the worst case.") }
        }
        Section("How it works") {
            Text("1. Every Net transfer goes into the buffer, not your spending account.\n2. On the 1st, move \(plan.paycheck.money) from the buffer to spending.\n3. Big months refill the buffer; slow months draw on it. Your budget sees the same income every month.").font(.subheadline)
        }
    }
}
