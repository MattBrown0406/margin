import SwiftUI
import SwiftData

/// Booked-but-unpaid jobs and the six-month cash-flow calendar they produce.
struct ForecastView: View {
    @Environment(\.modelContext) private var context
    let transactions: [Transaction]
    let categories: [BudgetCategory]
    let bookedJobs: [BookedJob]
    @State private var booking = false
    @State private var payingJob: BookedJob?

    private var openJobs: [BookedJob] { bookedJobs.filter(\.isOpen).sorted { $0.expectedDate < $1.expectedDate } }
    private var entries: [LedgerEntry] { transactions.map(\.ledgerEntry) }
    /// Payments already recorded (Add, bank import) that look like a booking's; those bookings stop counting.
    private var likelyPayments: [UUID: LedgerEntry] {
        CashFlowForecast.likelyPayments(for: openJobs.map(\.info), entries: entries, claimed: Set(bookedJobs.compactMap(\.paidJobID)))
    }
    private var months: [ForecastMonth] {
        CashFlowForecast.months(entries: entries, booked: BookedJob.expectedIncome(bookedJobs, entries: entries),
                                plannedMonthly: categories.reduce(0) { $0 + $1.monthlyLimit }, now: .now)
    }

    var body: some View {
        let months = months, likely = likelyPayments
        VStack(alignment: .leading, spacing: 14) {
            Text("Booked work, projected forward. Net expected from each booked job counts in the month it should pay.").font(.subheadline).foregroundStyle(.secondary)
            ForecastHeadline(months: months)
            VStack(spacing: 0) { ForEach(months) { ForecastMonthRow(month: $0); if $0.id != months.last?.id { Divider() } } }.marginCard()

            HStack { Text("Booked jobs").font(.title3.bold()); Spacer(); Button { booking = true } label: { Label("Book a job", systemImage: "plus") }.font(.subheadline.bold()).tint(.marginInk) }
            if openJobs.isEmpty {
                ContentUnavailableView("Nothing booked", systemImage: "calendar.badge.plus", description: Text("Add interventions you’ve booked so Margin can show which months are covered."))
            }
            ForEach(openJobs) { job in
                let overdue = job.expectedDate < Calendar.current.startOfDay(for: .now)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.title).font(.headline)
                            Text(overdue ? "Expected \(job.expectedDate.formatted(date: .abbreviated, time: .omitted)) · overdue" : "Expected \(job.expectedDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(overdue ? Color.marginCoral : .secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) { Text(job.expectedGross.money).bold(); Text("≈ \(job.expectedNet.money) Net").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let payment = likely[job.id] {
                        Label("Looks paid: \(payment.amount.money) on \(payment.date.formatted(date: .abbreviated, time: .omitted)) (“\(payment.title)”). It no longer counts as expected.", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if let payment = likely[job.id] {
                            Button("That’s it") { job.status = "paid"; job.paidJobID = payment.jobID; try? context.save() }.buttonStyle(.borderedProminent).tint(.marginInk)
                            Button("Not this one") { if let id = payment.jobID { job.ignoredPaymentIDs.append(id); try? context.save() } }.buttonStyle(.bordered)
                        } else {
                            Button("Mark paid") { payingJob = job }.buttonStyle(.borderedProminent).tint(.marginInk)
                        }
                        Spacer()
                        Menu { Button("Cancel booking", role: .destructive) { job.status = "cancelled"; try? context.save() } } label: { Image(systemName: "ellipsis").padding(8) }
                    }
                }.marginCard()
            }
        }
        .sheet(isPresented: $booking) { BookJobView(netRate: CashFlowForecast.historicalNetRate(entries: transactions.map(\.ledgerEntry), now: .now)) }
        .sheet(item: $payingJob) { job in
            MarkJobPaidView(job: job, recordedPayments: recordedPayments(near: job))
        }
    }
}

extension ForecastView {
    /// Recorded Gross receipts near a booking's date that no other booking has claimed, so Mark paid can link
    /// one instead of recording the same payment twice.
    func recordedPayments(near job: BookedJob) -> [Transaction] {
        let claimed = Set(bookedJobs.compactMap(\.paidJobID))
        let from = Calendar.current.date(byAdding: .day, value: -60, to: job.expectedDate) ?? .distantPast
        let to = Calendar.current.date(byAdding: .day, value: 60, to: job.expectedDate) ?? .distantFuture
        return transactions.filter { $0.isIncome && $0.incomeKind == "gross" && $0.jobID.map { !claimed.contains($0) } == true && $0.date >= from && $0.date <= to }
            .sorted { abs($0.date.timeIntervalSince(job.expectedDate)) < abs($1.date.timeIntervalSince(job.expectedDate)) }
    }
}

private struct ForecastHeadline: View {
    let months: [ForecastMonth]
    var body: some View {
        let short = CashFlowForecast.firstShortfall(months)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: short == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").font(.title2).foregroundStyle(short == nil ? Color.marginMint : Color.marginCoral)
            if let short {
                Text("\(short.monthStart.formatted(.dateTime.month(.wide))) runs \((-short.cumulative).money) short unless more work books for it.").font(.headline)
            } else if let last = months.last {
                Text("Booked work covers your plan through \(last.monthStart.formatted(.dateTime.month(.wide).year())).").font(.headline)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).marginCard()
    }
}

private struct ForecastMonthRow: View {
    let month: ForecastMonth
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(month.monthStart.formatted(.dateTime.month(.wide).year())).font(.subheadline.bold())
                Text(month.receivedNet > 0 ? "\(month.receivedNet.money) in + \(month.expectedNet.money) booked · plan \(month.planned.money)" : "\(month.expectedNet.money) booked · plan \(month.planned.money)")
                    .font(.caption).foregroundStyle(.secondary)
                if !month.overdueJobs.isEmpty { Text("Includes \(month.overdueJobs.count) overdue job\(month.overdueJobs.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(Color.marginCoral) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(month.isShort ? "Short \((-month.gap).money)" : "Covered +\(month.gap.money)").font(.subheadline.bold()).foregroundStyle(month.isShort ? Color.marginCoral : .green)
                Text("Running \(month.cumulative.money)").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 9)
    }
}

struct BookJobView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    /// Share of Gross that has reached the personal account historically; pre-fills the Net estimate.
    let netRate: Double?
    @State private var title = ""; @State private var gross = ""; @State private var net = ""; @State private var date = Date()
    /// The last Net estimate Margin filled in; once the person types something else, stop overwriting it.
    @State private var autoNet = ""
    @State private var netEdited = false

    private var rate: Double { netRate ?? 0.6 }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && Double(moneyInput: gross) != nil && (net.isEmpty || Double(moneyInput: net) != nil) }

    var body: some View { NavigationStack { Form {
        Section("Job") {
            TextField("Intervention or client", text: $title)
            TextField("Expected Gross", text: $gross).keyboardType(.decimalPad)
                .onChange(of: gross) { if !netEdited, let value = Double(moneyInput: gross) { autoNet = String(format: "%.0f", value * rate); net = autoNet } }
            DatePicker("Expected to pay", selection: $date, displayedComponents: .date)
        }
        Section {
            TextField("Expected Net to personal", text: $net).keyboardType(.decimalPad).onChange(of: net) { netEdited = !net.isEmpty && net != autoNet }
        } footer: {
            Text(netRate.map { "Pre-filled at \(Int(($0 * 100).rounded()))% of Gross, what has reached your personal account over the last year." } ?? "Pre-filled at 60% of Gross until Margin learns your usual transfer.")
        }
        Section { Button("Book job") { save() }.frame(maxWidth: .infinity).bold().disabled(!canSave) }
    }.navigationTitle("Book a job").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }

    private func save() {
        guard let grossValue = Double(moneyInput: gross) else { return }
        let netValue = Double(moneyInput: net) ?? (grossValue * rate).rounded()
        context.insert(BookedJob(title: title.trimmingCharacters(in: .whitespaces), expectedGross: grossValue, expectedNet: netValue, expectedDate: date))
        try? context.save(); dismiss()
    }
}

/// Turns a booked job into the real Gross receipt (and optionally its first Net transfer).
struct MarkJobPaidView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    let job: BookedJob
    let recordedPayments: [Transaction]
    @State private var gross = ""; @State private var date = Date(); @State private var net = ""; @State private var netDate = Date()
    @State private var existingJobID: UUID?

    private var canSave: Bool { existingJobID != nil || (Double(moneyInput: gross) != nil && (net.isEmpty || Double(moneyInput: net) != nil)) }

    var body: some View { NavigationStack { Form {
        if !recordedPayments.isEmpty {
            Section {
                Picker("Payment", selection: $existingJobID) {
                    Text("Record a new payment").tag(UUID?.none)
                    ForEach(recordedPayments) { tx in Text("\(tx.title) · \(tx.amount.money) · \(tx.date.formatted(date: .abbreviated, time: .omitted))").tag(tx.jobID) }
                }
            } header: { Text("Already recorded?") } footer: { Text("If this payment came in through Add or a bank import, link it so it isn’t counted twice.") }
        }
        if existingJobID == nil {
        Section("Received by business") { TextField("Gross received", text: $gross).keyboardType(.decimalPad); DatePicker("Date received", selection: $date, displayedComponents: .date) }
        Section { TextField("Net transferred personal", text: $net).keyboardType(.decimalPad); DatePicker("Transfer date", selection: $netDate, displayedComponents: .date) }
            header: { Text("Net transfer — optional") } footer: { Text("Leave blank until money actually moves to your personal account.") }
        }
        Section { Button(existingJobID == nil ? "Record payment" : "Link payment") { save() }.frame(maxWidth: .infinity).bold().disabled(!canSave) }
    }.navigationTitle(job.title).onAppear { gross = String(format: "%.2f", job.expectedGross) }
     .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }

    private func save() {
        if let existingJobID {
            job.status = "paid"; job.paidJobID = existingJobID
            try? context.save(); dismiss(); return
        }
        guard let grossValue = Double(moneyInput: gross) else { return }
        let jobID = UUID()
        context.insert(Transaction(title: job.title, amount: grossValue, date: date, category: "Intervention income", isIncome: true, ledgerScope: "business", incomeKind: "gross", jobID: jobID))
        if let netValue = Double(moneyInput: net) { context.insert(Transaction(title: job.title, amount: netValue, date: netDate, category: "Owner transfer", isIncome: true, ledgerScope: "personal", incomeKind: "net", jobID: jobID)) }
        job.status = "paid"; job.paidJobID = jobID
        try? context.save(); dismiss()
    }
}
