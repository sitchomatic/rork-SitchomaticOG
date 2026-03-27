import Foundation
import CoreXLSX

nonisolated struct XLSXParserService: Sendable {
    static func parseToCSV(url: URL) -> String? {
        guard let file = XLSXFile(filepath: url.path) else { return nil }

        do {
            let sharedStrings = try? file.parseSharedStrings()
            let paths = try file.parseWorksheetPaths()
            guard let firstPath = paths.first else { return nil }

            let worksheet = try file.parseWorksheet(at: firstPath)
            guard let rows = worksheet.data?.rows, !rows.isEmpty else { return nil }

            var csvLines: [String] = []

            for row in rows {
                var cellValues: [String] = []
                for cell in row.cells {
                    let value = cellStringValue(cell, sharedStrings: sharedStrings)
                    cellValues.append(escapeCSVField(value))
                }
                csvLines.append(cellValues.joined(separator: ","))
            }

            let result = csvLines.joined(separator: "\n")
            return result.isEmpty ? nil : result
        } catch {
            return nil
        }
    }

    private static func cellStringValue(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let shared = sharedStrings, let str = cell.stringValue(shared) {
            return str
        }

        if let inlineStr = cell.inlineString?.text {
            return inlineStr
        }

        if let value = cell.value {
            return value
        }

        return ""
    }

    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
}
