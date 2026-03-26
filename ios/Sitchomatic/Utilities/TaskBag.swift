import Foundation

@MainActor
final class TaskBag {
    private var tasks: [String: Task<Void, Never>] = [:]

    func add(_ key: String, _ task: Task<Void, Never>) {
        tasks[key]?.cancel()
        tasks[key] = task
    }

    func cancel(_ key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }

    var activeKeys: [String] {
        Array(tasks.keys)
    }

    var count: Int { tasks.count }

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }
}
