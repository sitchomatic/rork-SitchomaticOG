import Foundation
import SwiftUI
import UIKit

@Observable
@MainActor
class EvidenceBundleViewModel {
    static let shared = EvidenceBundleViewModel()

    private let service = EvidenceBundleService.shared
    private let screenshotCache = ScreenshotCacheService.shared

    var selectedFilter: BundleFilter = .all
    var searchText: String = ""
    var selectedBundle: EvidenceBundle?
    var showShareSheet: Bool = false
    var shareData: Data?
    var shareText: String?

    enum BundleFilter: String, CaseIterable {
        case all = "All"
        case working = "Working"
        case noAcc = "No Acc"
        case tempDis = "Temp Dis"
        case permDis = "Perm Dis"
        case unsure = "Unsure"
        case exported = "Exported"
    }

    var filteredBundles: [EvidenceBundle] {
        let base: [EvidenceBundle]
        switch selectedFilter {
        case .all: base = service.bundles
        case .working: base = service.bundles.filter { $0.resultStatus == .working }
        case .noAcc: base = service.bundles.filter { $0.resultStatus == .noAcc }
        case .tempDis: base = service.bundles.filter { $0.resultStatus == .tempDisabled }
        case .permDis: base = service.bundles.filter { $0.resultStatus == .permDisabled }
        case .unsure: base = service.bundles.filter { $0.resultStatus == .unsure }
        case .exported: base = service.bundles.filter { $0.isExported }
        }
        if searchText.isEmpty { return base }
        return base.filter {
            $0.username.localizedStandardContains(searchText) ||
            $0.testedURL.localizedStandardContains(searchText) ||
            $0.outcomeLabel.localizedStandardContains(searchText)
        }
    }

    var totalCount: Int { service.totalCount }
    var exportedCount: Int { service.exportedCount }

    func countFor(_ filter: BundleFilter) -> Int {
        switch filter {
        case .all: service.bundles.count
        case .working: service.bundles.filter { $0.resultStatus == .working }.count
        case .noAcc: service.bundles.filter { $0.resultStatus == .noAcc }.count
        case .tempDis: service.bundles.filter { $0.resultStatus == .tempDisabled }.count
        case .permDis: service.bundles.filter { $0.resultStatus == .permDisabled }.count
        case .unsure: service.bundles.filter { $0.resultStatus == .unsure }.count
        case .exported: service.bundles.filter { $0.isExported }.count
        }
    }

    func exportJSON(_ bundle: EvidenceBundle) {
        guard let data = service.exportAsJSON(bundle) else { return }
        service.markExported(bundle)
        shareData = data
        shareText = nil
        showShareSheet = true
    }

    func exportText(_ bundle: EvidenceBundle) {
        let text = service.exportAsText(bundle)
        service.markExported(bundle)
        shareData = nil
        shareText = text
        showShareSheet = true
    }

    func exportBatchJSON() {
        let selected = filteredBundles.filter { !$0.isExported }
        guard !selected.isEmpty else { return }
        guard let data = service.exportBatchAsJSON(selected) else { return }
        for b in selected { service.markExported(b) }
        shareData = data
        shareText = nil
        showShareSheet = true
    }

    func exportAllJSON() {
        guard let data = service.exportBatchAsJSON(service.bundles) else { return }
        for b in service.bundles { service.markExported(b) }
        shareData = data
        shareText = nil
        showShareSheet = true
    }

    func clearExported() { service.clearExported() }
    func clearAll() { service.clearAll() }

    func screenshot(for id: String) -> UIImage? {
        screenshotCache.retrieve(forKey: id)
    }

    func screenshots(for bundle: EvidenceBundle) -> [UIImage] {
        service.screenshotImages(for: bundle)
    }

    var shareItems: [Any] {
        var items: [Any] = []
        if let data = shareData { items.append(data) }
        if let text = shareText { items.append(text) }
        return items
    }
}
