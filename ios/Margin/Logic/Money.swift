import Foundation

extension Double {
    var money: String { formatted(.currency(code: "USD").precision(.fractionLength(0))) }
    /// Exact amount for individual transactions, where rounding to whole dollars would misstate them.
    var moneyExact: String { formatted(.currency(code: "USD")) }

    /// Parses a typed or pasted amount such as "1,234.50", "$12", "12,50", "1 234,56" or "USD 40", rounded to
    /// cents. Currency symbols, codes and spaces may surround the number, but anything else inside it ("Invoice
    /// #1042 $750", "3 for $10", "1e3", "50¢") is rejected rather than guessed at. The decimal mark is inferred
    /// from the text: the last "." or "," is decimal unless it is the locale's grouping mark followed by exactly
    /// three digits, so a pasted "12.50" still means 12.50 in comma-decimal locales.
    /// Returns nil for anything that isn't a positive amount of at least one cent.
    init?(moneyInput text: String, locale: Locale = .current) {
        let edge: (Character) -> Bool = { $0.isWhitespace || "$€£¥₹".contains($0) || ($0.isASCII && $0.isLetter) }
        var core = Substring(text)
        while let c = core.first, edge(c) { core.removeFirst() }
        while let c = core.last, edge(c) { core.removeLast() }
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
              groups.count == 1 || (head.count <= 3 && groups.dropFirst().allSatisfy { $0.count == 3 }) else { return nil }

        guard let value = Double(groups.joined() + (fraction.isEmpty ? "" : "." + fraction)), value.isFinite else { return nil }
        let cents = (value * 100).rounded() / 100
        guard cents > 0 else { return nil }
        self = cents
    }
}
