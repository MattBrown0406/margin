import Foundation

extension Double {
    var money: String { formatted(.currency(code: "USD").precision(.fractionLength(0))) }
    var wholePercent: String { formatted(.percent.precision(.fractionLength(0))) }
    /// Exact amount for individual transactions, where rounding to whole dollars would misstate them.
    var moneyExact: String { formatted(.currency(code: "USD")) }

    /// Parses a typed or pasted amount such as "1,234.50", "$12", "12,50", "1 234,56" or "USD 40", rounded to
    /// cents. Currency symbols, codes and spaces may surround the number, but anything else inside it ("Invoice
    /// #1042 $750", "3 for $10", "1e3", "50¢") is rejected rather than guessed at. The decimal mark is inferred
    /// from the text: the last "." or "," is decimal unless it is the locale's grouping mark followed by exactly
    /// three digits, so a pasted "12.50" still means 12.50 in comma-decimal locales.
    /// Positive amounts must round to at least one cent. Statement and planning fields can also accept explicit zero.
    init?(moneyInput text: String, locale: Locale = .current, allowZero: Bool = false) {
        // Only currency markers may surround the number; "5k", "50 cents" or "Invoice 1042" are rejected.
        var core = Substring(text).trimmingCharacters(in: .whitespacesAndNewlines)[...]
        for marker in ["US$", "USD", "$", "€", "£", "¥", "₹"] {
            if core.uppercased().hasPrefix(marker) { core = core.dropFirst(marker.count) }
            if core.uppercased().hasSuffix(marker) { core = core.dropLast(marker.count) }
        }
        core = core.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if allowZero, core.range(of: #"^0+([.,]0+)?$"#, options: .regularExpression) != nil {
            self = 0
            return
        }
        let isDigit: (Character) -> Bool = { ("0"..."9").contains($0) }
        let isMark: (Character) -> Bool = { $0 == "." || $0 == "," }
        let groupingOnly: Set<Character> = [" ", "'", "\u{00A0}", "\u{202F}"]
        guard !core.isEmpty, core.allSatisfy({ isDigit($0) || isMark($0) || groupingOnly.contains($0) }) else { return nil }
        if let first = core.first, isMark(first) { core = "0" + core }       // ".50"

        var decimalMark: Character?
        if let last = core.lastIndex(where: isMark) {
            let mark = core[last], fractionDigits = core.distance(from: core.index(after: last), to: core.endIndex)
            let marks = core.filter(isMark)
            let mixed = marks.contains(".") && marks.contains(","), repeated = marks.filter { $0 == mark }.count > 1
            if mixed || (!repeated && (mark == Character(locale.decimalSeparator ?? ".") || fractionDigits != 3)) { decimalMark = mark }
        }
        var integer = core, fraction: Substring = ""
        if let mark = decimalMark, let i = core.lastIndex(of: mark) { integer = core[..<i]; fraction = core[core.index(after: i)...] }
        guard fraction.allSatisfy(isDigit) else { return nil }
        // Whole part: plain digits, or 1–3 digits then groups of exactly three joined by one kind of separator.
        let groups = integer.split(omittingEmptySubsequences: false) { !isDigit($0) }
        guard let head = groups.first, !head.isEmpty, Set(integer.filter { !isDigit($0) }).count <= 1,
              // A grouped number can't start with a 0 group: "0,001" or "0.005" is a typo, not a thousand.
              groups.count == 1 || (head.count <= 3 && head != "0" && groups.dropFirst().allSatisfy { $0.count == 3 }) else { return nil }

        // Round the decimal text before converting to Double (1.005 is exactly 101 cents).
        let centDigits = fraction.prefix(2)
        guard var cents = UInt64(groups.joined() + String(centDigits) + String(repeating: "0", count: 2 - centDigits.count)),
              cents < (1 << 52) else { return nil }
        if fraction.dropFirst(2).first.map({ $0 >= "5" }) == true { cents += 1 }
        guard cents > 0 else { return nil }
        self = Double(cents) / 100
    }
}
