import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MarginXLSXDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "xlsx") ?? .data
    static var readableContentTypes: [UTType] { [contentType] }
    private var data: Data

    init(transactions: [Transaction], categories: [BudgetCategory]) {
        data = XLSXExporter.makeWorkbook(transactions: transactions, categories: categories)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum WorkbookCell {
    case text(String)
    case number(Double)
}

private struct WorkbookSheet {
    let name: String
    let rows: [[WorkbookCell]]
}

enum XLSXExporter {
    static func makeWorkbook(transactions: [Transaction], categories: [BudgetCategory]) -> Data {
        let calendar = Calendar.current
        let month = transactions.filter { calendar.isDate($0.date, equalTo: .now, toGranularity: .month) }
        let grossRows = month.filter { $0.isIncome && $0.incomeKind == "gross" }.sorted { $0.date < $1.date }
        let expenses = month.filter { !$0.isIncome }.sorted { $0.date < $1.date }
        let gross = grossRows.reduce(0) { $0 + $1.amount }
        let net = month.filter { $0.isIncome && $0.incomeKind == "net" }.reduce(0) { $0 + $1.amount }
        let businessSpend = expenses.filter { $0.ledgerScope == "business" }.reduce(0) { $0 + $1.amount }
        let personalSpend = expenses.filter { $0.ledgerScope == "personal" }.reduce(0) { $0 + $1.amount }

        var incomeRows: [[WorkbookCell]] = [[.text("Date received"), .text("Intervention / job"), .text("Gross received by business"), .text("Net transferred personal"), .text("Transfer date")]]
        for entry in grossRows {
            let transfer = transactions.first { $0.isIncome && $0.incomeKind == "net" && $0.jobID == entry.jobID }
            incomeRows.append([.text(date(entry.date)), .text(entry.title), .number(entry.amount), transfer.map { .number($0.amount) } ?? .text("Not transferred"), .text(transfer.map { date($0.date) } ?? "")])
        }

        var expenseRows: [[WorkbookCell]] = [[.text("Date"), .text("Ledger"), .text("Description"), .text("Category"), .text("Amount"), .text("Source")]]
        expenseRows += expenses.map { [.text(date($0.date)), .text($0.ledgerScope.capitalized), .text($0.title), .text($0.category), .number($0.amount), .text($0.externalID == nil ? "Manual" : "Bank import")] }

        var budgetRows: [[WorkbookCell]] = [[.text("Group"), .text("Category"), .text("Planned"), .text("Personal spent"), .text("Remaining")]]
        for category in categories.sorted(by: { ($0.groupName, $0.name) < ($1.groupName, $1.name) }) {
            let spent = expenses.filter { $0.ledgerScope == "personal" && $0.category == category.name }.reduce(0) { $0 + $1.amount }
            budgetRows.append([.text(category.groupName), .text(category.name), .number(category.monthlyLimit), .number(spent), .number(category.monthlyLimit - spent)])
        }

        let grouped = Dictionary(grouping: expenses) { "\($0.ledgerScope.capitalized) — \($0.category)" }
        var categoryRows: [[WorkbookCell]] = [[.text("Ledger and category"), .text("Total spent")]]
        for key in grouped.keys.sorted() { categoryRows.append([.text(key), .number(grouped[key, default: []].reduce(0) { $0 + $1.amount })]) }

        let summaryRows: [[WorkbookCell]] = [
            [.text("MARGIN MONTHLY REPORT")],
            [.text("Report month"), .text(Date.now.formatted(.dateTime.month(.wide).year()))],
            [.text("Business gross received"), .number(gross)],
            [.text("Business expenses"), .number(businessSpend)],
            [.text("Net transferred to personal"), .number(net)],
            [.text("Retained in business"), .number(gross - businessSpend - net)],
            [.text("Personal expenses"), .number(personalSpend)],
            [.text("Personal margin"), .number(net - personalSpend)],
            [.text("Note"), .text("Gross is money received from interventions. Net is money actually transferred from the business account to the personal account.")]
        ]

        let sheets = [
            WorkbookSheet(name: "Summary", rows: summaryRows),
            WorkbookSheet(name: "Income & Jobs", rows: incomeRows),
            WorkbookSheet(name: "Expenses", rows: expenseRows),
            WorkbookSheet(name: "Budget", rows: budgetRows),
            WorkbookSheet(name: "Category Totals", rows: categoryRows)
        ]
        return package(sheets)
    }

    private static func package(_ sheets: [WorkbookSheet]) -> Data {
        var files: [(String, Data)] = []
        files.append(("[Content_Types].xml", xmlData(contentTypes(sheetCount: sheets.count))))
        files.append(("_rels/.rels", xmlData(rootRelationships)))
        files.append(("docProps/app.xml", xmlData(appProperties(sheetNames: sheets.map(\.name)))))
        files.append(("docProps/core.xml", xmlData(coreProperties)))
        files.append(("xl/workbook.xml", xmlData(workbook(sheetNames: sheets.map(\.name)))))
        files.append(("xl/_rels/workbook.xml.rels", xmlData(workbookRelationships(sheetCount: sheets.count))))
        files.append(("xl/styles.xml", xmlData(styles)))
        for (index, sheet) in sheets.enumerated() { files.append(("xl/worksheets/sheet\(index + 1).xml", xmlData(worksheet(sheet.rows)))) }
        return ZipStore.archive(files)
    }

    private static func worksheet(_ rows: [[WorkbookCell]]) -> String {
        let body = rows.enumerated().map { rowIndex, row in
            let cells = row.enumerated().map { columnIndex, cell in
                let reference = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                let style = rowIndex == 0 ? 1 : (isNumber(cell) ? 2 : 0)
                switch cell {
                case .text(let value): return "<c r=\"\(reference)\" t=\"inlineStr\" s=\"\(style)\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
                case .number(let value): return "<c r=\"\(reference)\" s=\"\(style)\"><v>\(value)</v></c>"
                }
            }.joined()
            return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }.joined()
        let widths = "<cols><col min=\"1\" max=\"1\" width=\"20\" customWidth=\"1\"/><col min=\"2\" max=\"8\" width=\"24\" customWidth=\"1\"/></cols>"
        return xmlHeader + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(widths)<sheetData>\(body)</sheetData></worksheet>"
    }

    private static func isNumber(_ cell: WorkbookCell) -> Bool { if case .number = cell { return true }; return false }
    private static func columnName(_ number: Int) -> String { var n = number, result = ""; while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }; return result }
    private static func escape(_ string: String) -> String { string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    private static func date(_ value: Date) -> String { value.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) }
    private static func xmlData(_ string: String) -> Data { Data(string.utf8) }
    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

    private static func contentTypes(sheetCount: Int) -> String { xmlHeader + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>" + (1...sheetCount).map { "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined() + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/></Types>" }
    private static let rootRelationships = xmlHeader + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>"
    private static func workbook(sheetNames: [String]) -> String { xmlHeader + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>" + sheetNames.enumerated().map { "<sheet name=\"\(escape($0.element))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined() + "</sheets></workbook>" }
    private static func workbookRelationships(sheetCount: Int) -> String { xmlHeader + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + (1...sheetCount).map { "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>" }.joined() + "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>" }
    private static let styles = xmlHeader + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"$#,##0.00\"/></numFmts><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Aptos\"/></font><font><b/><color rgb=\"FFFFFFFF\"/><sz val=\"11\"/><name val=\"Aptos\"/></font></fonts><fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF132124\"/><bgColor indexed=\"64\"/></patternFill></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"3\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFill=\"1\"/><xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
    private static let coreProperties = xmlHeader + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>Margin Financial Report</dc:title><dc:creator>Margin</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">2026-08-02T00:00:00Z</dcterms:created></cp:coreProperties>"
    private static func appProperties(sheetNames: [String]) -> String { xmlHeader + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"><Application>Margin</Application><TitlesOfParts><vt:vector size=\"\(sheetNames.count)\" baseType=\"lpstr\">" + sheetNames.map { "<vt:lpstr>\(escape($0))</vt:lpstr>" }.joined() + "</vt:vector></TitlesOfParts></Properties>" }
}

private enum ZipStore {
    private struct Entry { let name: Data; let payload: Data; let crc: UInt32; let offset: UInt32 }
    static func archive(_ files: [(String, Data)]) -> Data {
        var output = Data(), entries: [Entry] = []
        for (nameString, payload) in files {
            let name = Data(nameString.utf8), crc = crc32(payload), offset = UInt32(output.count)
            output.appendLE(UInt32(0x04034b50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(crc); output.appendLE(UInt32(payload.count)); output.appendLE(UInt32(payload.count)); output.appendLE(UInt16(name.count)); output.appendLE(UInt16(0)); output.append(name); output.append(payload)
            entries.append(Entry(name: name, payload: payload, crc: crc, offset: offset))
        }
        let centralOffset = UInt32(output.count)
        for entry in entries {
            output.appendLE(UInt32(0x02014b50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(entry.crc); output.appendLE(UInt32(entry.payload.count)); output.appendLE(UInt32(entry.payload.count)); output.appendLE(UInt16(entry.name.count)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt32(0)); output.appendLE(entry.offset); output.append(entry.name)
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.appendLE(UInt32(0x06054b50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt16(entries.count)); output.appendLE(centralSize); output.appendLE(centralOffset); output.appendLE(UInt16(0))
        return output
    }
    private static func crc32(_ data: Data) -> UInt32 { var crc: UInt32 = 0xffffffff; for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb88320 & (0 &- (crc & 1))) } }; return crc ^ 0xffffffff }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) } }
}
