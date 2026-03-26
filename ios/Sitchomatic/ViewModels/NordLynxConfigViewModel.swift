import SwiftUI

nonisolated enum NordLynxGenerationState: Sendable, Equatable {
    case idle
    case loading
    case success(Int)
    case error(String)
}

@Observable
@MainActor
final class NordLynxConfigViewModel {
    var serverLimit: Int = 5
    var configs: [NordLynxGeneratedConfig] = []
    var state: NordLynxGenerationState = .idle
    var savedFolderURL: URL?
    var exportURLs: [URL] = []
    var searchText: String = ""

    var countries: [NordLynxCountryResponse] = []
    var selectedCountry: NordLynxCountryResponse?
    var selectedCity: NordLynxCountryResponse.CityResponse?
    var isLoadingCountries: Bool = false

    var selectedProtocol: NordLynxVPNProtocol = .wireguardUDP

    var isExporting: Bool = false
    var exportedURL: URL?
    var selectedExportFormat: NordLynxExportFormat = .individualFiles

    private let service = NordLynxAPIService()
    private let generator = NordLynxConfigGeneratorService()
    private let exportService = NordLynxExportService()
    private var countriesLoaded: Bool = false

    var activeKeyName: String {
        NordLynxConfigGeneratorService.activeAccessKey.name
    }

    var canGenerate: Bool {
        if case .loading = state { return false }
        return serverLimit >= 1 && serverLimit <= 50
    }

    var availableCities: [NordLynxCountryResponse.CityResponse] {
        guard let country = selectedCountry,
              let cities = country.cities, !cities.isEmpty else { return [] }
        return cities.sorted { $0.name < $1.name }
    }

    var filteredConfigs: [NordLynxGeneratedConfig] {
        var result = configs

        if let city = selectedCity, !city.name.isEmpty {
            result = result.filter { $0.cityName.localizedStandardContains(city.name) }
        }

        guard !searchText.isEmpty else { return result }
        return result.filter {
            $0.hostname.localizedStandardContains(searchText) ||
            $0.stationIP.localizedStandardContains(searchText) ||
            $0.countryName.localizedStandardContains(searchText) ||
            $0.cityName.localizedStandardContains(searchText)
        }
    }

    var filteredExportURLs: [URL] {
        guard let folder = savedFolderURL else { return [] }
        return filteredConfigs.compactMap { config in
            let url = folder.appending(path: config.fileName)
            return FileManager.default.fileExists(atPath: url.path()) ? url : nil
        }
    }

    func loadCountries() async {
        guard !countriesLoaded else { return }
        isLoadingCountries = true
        defer { isLoadingCountries = false }
        do {
            countries = try await service.fetchCountries()
            countriesLoaded = true
        } catch {
            countries = []
        }
    }

    func selectCountry(_ country: NordLynxCountryResponse?) {
        selectedCountry = country
        selectedCity = nil
    }

    func generateConfigs() async {
        state = .loading
        configs = []
        savedFolderURL = nil
        exportURLs = []
        searchText = ""
        exportedURL = nil
        selectedExportFormat = .individualFiles

        do {
            let servers = try await service.fetchServers(
                limit: serverLimit,
                countryId: selectedCountry?.id,
                vpnProtocol: selectedProtocol
            )

            guard !servers.isEmpty else {
                state = .error("No servers returned from NordVPN API.")
                return
            }

            let generated = try await generator.generate(from: servers, vpnProtocol: selectedProtocol)
            let folderURL = try generator.saveToDocuments(generated)

            configs = generated
            savedFolderURL = folderURL
            exportURLs = generated.map { folderURL.appending(path: $0.fileName) }
            state = .success(generated.count)
        } catch let error as NordLynxAPIError {
            state = .error(error.localizedDescription)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private var exportLabel: String {
        let countryLabel = selectedCountry?.code.uppercased() ?? "All"
        let protoLabel = selectedProtocol.shortName.replacingOccurrences(of: " ", with: "_")
        return "NordVPN_\(protoLabel)_\(countryLabel)_\(filteredConfigs.count)"
    }

    func exportConfigs(format: NordLynxExportFormat) async {
        guard let folderURL = savedFolderURL else { return }
        isExporting = true
        exportedURL = nil
        defer { isExporting = false }

        do {
            switch format {
            case .individualFiles:
                break
            case .zipArchive:
                exportedURL = try exportService.exportAsZip(configs: filteredConfigs, folderURL: folderURL, label: exportLabel)
            case .mergedText:
                exportedURL = try exportService.exportAsMergedText(configs: filteredConfigs, label: exportLabel)
            case .json:
                exportedURL = try exportService.exportAsJSON(configs: filteredConfigs, label: exportLabel)
            case .csv:
                exportedURL = try exportService.exportAsCSV(configs: filteredConfigs, label: exportLabel)
            }
        } catch {
            exportedURL = nil
        }
    }

    func reset() {
        withAnimation(.smooth(duration: 0.3)) {
            configs = []
            state = .idle
            savedFolderURL = nil
            exportURLs = []
            searchText = ""
            exportedURL = nil
            selectedExportFormat = .individualFiles
        }
    }

    func importGeneratedToApp() -> (wg: Int, ovpn: Int) {
        let proxyService = ProxyRotationService.shared
        var wgCount = 0
        var ovpnCount = 0
        for config in filteredConfigs {
            if config.vpnProtocol == .wireguardUDP {
                if let wgConfig = WireGuardConfig.parse(fileName: config.hostname, content: config.fileContent) {
                    for target: ProxyRotationService.ProxyTarget in [.joe, .ignition, .ppsr] {
                        proxyService.importWGConfig(wgConfig, for: target)
                    }
                    wgCount += 1
                }
            } else {
                if let ovpnConfig = OpenVPNConfig.parse(fileName: config.fileName, content: config.fileContent) {
                    for target: ProxyRotationService.ProxyTarget in [.joe, .ignition, .ppsr] {
                        proxyService.importVPNConfig(ovpnConfig, for: target)
                    }
                    ovpnCount += 1
                }
            }
        }
        return (wgCount, ovpnCount)
    }
}
