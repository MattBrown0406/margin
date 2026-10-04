import Foundation

extension Double {
    var money: String { formatted(.currency(code: "USD").precision(.fractionLength(0))) }
    /// Exact amount for individual transactions, where rounding to whole dollars would misstate them.
    var moneyExact: String { formatted(.currency(code: "USD")) }

    /// Parses a typed or pasted amount such as "1,234.50", "$12", "12,50" or "1 234,56", rounded to cents.
    /// The decimal separator is inferred from the text (the last "." or "," is a decimal point unless it is
    /// the locale's grouping mark followed by exactly three digits), so a pasted "12.50" still means 12.50
    /// in comma-decimal locales. Returns nil for anything that isn't a positive amount of at least one cent.
    init?(moneyInput text: String, locale: Locale = .current) {
        guard !text.contains("-"), !text.contains("−") else { return nil }
        let kept = text.filter { ("0"..."9").contains($0) || $0 == "." || $0 == "," }
        var normalized = kept.filter { ("0"..."9").contains($0) }
        if let last = kept.lastIndex(where: { $0 == "." || $0 == "," }) {
            let separator = kept[last], fractionDigits = kept.distance(from: kept.index(after: last), to: kept.endIndex)
            let mixed = kept.contains(".") && kept.contains(","), repeated = kept.filter { $0 == separator }.count > 1
            let localeDecimal = Character(locale.decimalSeparator ?? ".")
            let isDecimal = mixed || (!repeated && (separator == localeDecimal || fractionDigits != 3))
            if isDecimal { normalized = kept[..<last].filter { ("0"..."9").contains($0) } + "." + kept[kept.index(after: last)...] }
        }
        guard let value = Double(normalized), value.isFinite else { return nil }
        let cents = (value * 100).rounded() / 100
        guard cents > 0 else { return nil }
        self = cents
    }
}
