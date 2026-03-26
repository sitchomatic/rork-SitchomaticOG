import Foundation
import Observation
import SwiftUI
import UIKit

@Observable
@MainActor
class ReviewQueueViewModel {
    static let shared = ReviewQueueViewModel()

    private let service = ReviewQueueService.shared
    private let screenshotCache = ScreenshotCacheService.shared

    var selectedFilter: ReviewFilter = .pending
    var searchText: String = ""
    var showOverridePicker: Bool = false
    var selectedItem: ReviewItem?

    enum ReviewFilter: String, CaseIterable {
        case pending = "Pending"
        case resolved = "Resolved"
        case expired = "Expired"
        case all = "All"
    }

    var filteredItems: [ReviewItem] {
        let base: [ReviewItem]
        switch selectedFilter {
        case .pending:
            base = service.items.filter { !$0.isResolved && !$0.isExpired }
        case .resolved:
            base = service.items.filter { $0.isResolved }
        case .expired:
            base = service.items.filter { !$0.isResolved && $0.isExpired }
        case .all:
            base = service.items
        }

        if searchText.isEmpty { return base }
        return base.filter {
            $0.username.localizedStandardContains(searchText) ||
            $0.suggestedStatusLabel.localizedStandardContains(searchText) ||
            $0.testedURL.localizedStandardContains(searchText)
        }
    }

    var pendingCount: Int { service.pendingCount }
    var resolvedCount: Int { service.resolvedCount }
    var expiredCount: Int { service.expiredCount }
    var totalCount: Int { service.items.count }

    func approve(_ item: ReviewItem) {
        service.approveEngineSuggestion(item)
    }

    func override(_ item: ReviewItem, as status: CredentialStatus) {
        service.resolveItem(item, as: status)
    }

    func expireOld() {
        service.expireOldItems()
    }

    func clearResolved() {
        service.removeResolved()
    }

    func clearAll() {
        service.clearAll()
    }

    func screenshot(for id: String) -> UIImage? {
        screenshotCache.retrieve(forKey: id)
    }
}
