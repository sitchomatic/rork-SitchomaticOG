import Foundation

nonisolated struct NordLynxExportService: Sendable {
    private let zipService = NordLynxZipService()

    func exportAsIndividualFiles(configs: [NordLynxGeneratedConfig], folderURL: URL) -> [URL] {
        configs.map { folderURL.appending(path: $0.fileName) }
    }

    func exportAsZip(configs: [NordLynxGeneratedConfig], folderURL: URL, label: String) throws -> URL {
        try zipService.createZip(from: folderURL, zipName: label)
    }

    func exportAsMergedText(configs: [NordLynxGeneratedConfig], label: String) throws -> URL {
        let separator = String(repeating: "─", count: 60)
        var merged = "# \(label)\n# Generated \(configs.count) configs on \(formattedDate)\n\n"

        for (index, config) in configs.enumerated() {
            merged += "# [\(index + 1)] \(config.hostname) — \(config.countryName), \(config.cityName)\n"
            merged += "# Load: \(config.serverLoad)% | Protocol: \(config.vpnProtocol.shortName)\n"
            merged += separator + "\n\n"
            merged += config.fileContent
            merged += "\n\n"
        }

        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appending(path: "\(label).txt")
        try merged.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func exportAsJSON(configs: [NordLynxGeneratedConfig], label: String) throws -> URL {
        let entries: [[String: Any]] = configs.map { config in
            [
                "hostname": config.hostname,
                "station_ip": config.stationIP,
                "public_key": config.publicKey,
                "country": config.countryName,
                "country_code": config.countryCode,
                "city": config.cityName,
                "server_load": config.serverLoad,
                "protocol": config.vpnProtocol.displayName,
                "port": config.port,
                "file_name": config.fileName,
                "config_content": config.fileContent
            ]
        }

        let wrapper: [String: Any] = [
            "generated_at": formattedDate,
            "count": configs.count,
            "configs": entries
        ]

        let data = try JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys])

        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appending(path: "\(label).json")
        try data.write(to: fileURL)
        return fileURL
    }

    func exportAsCSV(configs: [NordLynxGeneratedConfig], label: String) throws -> URL {
        var csv = "Hostname,Station IP,Public Key,Country,Country Code,City,Server Load,Protocol,Port,File Name\n"

        for config in configs {
            let row = [
                escapeCSV(config.hostname),
                escapeCSV(config.stationIP),
                escapeCSV(config.publicKey),
                escapeCSV(config.countryName),
                escapeCSV(config.countryCode),
                escapeCSV(config.cityName),
                "\(config.serverLoad)",
                escapeCSV(config.vpnProtocol.displayName),
                "\(config.port)",
                escapeCSV(config.fileName)
            ].joined(separator: ",")
            csv += row + "\n"
        }

        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appending(path: "\(label).csv")
        try csv.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private var formattedDate: String {
        DateFormatters.mediumDateTime.string(from: Date())
    }
}
