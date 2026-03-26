import Foundation

nonisolated enum NordLynxExportFormat: String, CaseIterable, Identifiable, Sendable {
    case individualFiles
    case zipArchive
    case mergedText
    case json
    case csv

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .individualFiles: "Individual Files"
        case .zipArchive: "ZIP Archive"
        case .mergedText: "Merged Text"
        case .json: "JSON"
        case .csv: "CSV"
        }
    }

    var icon: String {
        switch self {
        case .individualFiles: "doc.on.doc"
        case .zipArchive: "doc.zipper"
        case .mergedText: "doc.text"
        case .json: "curlybraces"
        case .csv: "tablecells"
        }
    }

    var fileExtension: String {
        switch self {
        case .individualFiles: ""
        case .zipArchive: "zip"
        case .mergedText: "txt"
        case .json: "json"
        case .csv: "csv"
        }
    }

    var subtitle: String {
        switch self {
        case .individualFiles: "Share .conf/.ovpn files separately"
        case .zipArchive: "All configs in one compressed file"
        case .mergedText: "All configs combined in a single .txt"
        case .json: "Structured data for automation"
        case .csv: "Spreadsheet-compatible server list"
        }
    }
}
