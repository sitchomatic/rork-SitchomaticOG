import Foundation
import Observation

@Observable
@MainActor
class NoticesService {
    static let shared = NoticesService()

    var notices: [FailureNotice] = []

    func addNotice(message: String, source: FailureNotice.Source, autoRetried: Bool = false) {
        let notice = FailureNotice(message: message, source: source, autoRetried: autoRetried)
        notices.insert(notice, at: 0)
        if notices.count > 500 {
            notices.removeLast(notices.count - 500)
        }
    }

    func clearNotices() {
        notices.removeAll()
    }

    func clearNotices(for source: FailureNotice.Source) {
        notices.removeAll { $0.source == source }
    }

    var unreadCount: Int { notices.count }

    func noticesForSource(_ source: FailureNotice.Source) -> [FailureNotice] {
        notices.filter { $0.source == source }
    }
}
