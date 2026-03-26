import Foundation

@MainActor
class TestSchedulerService {
    static let shared = TestSchedulerService()

    private let storageKey = "test_schedules_v1"
    private(set) var schedules: [TestSchedule] = []
    private var monitorTask: Task<Void, Never>?

    var onScheduleTriggered: ((TestSchedule) -> Void)?

    init() {
        loadSchedules()
    }

    func addSchedule(_ schedule: TestSchedule) {
        schedules.append(schedule)
        saveSchedules()
        startMonitoring()
    }

    func removeSchedule(_ schedule: TestSchedule) {
        schedules.removeAll { $0.id == schedule.id }
        saveSchedules()
    }

    func updateSchedule(_ schedule: TestSchedule) {
        if let idx = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[idx] = schedule
            saveSchedules()
        }
    }

    func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                checkPendingSchedules()
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func checkPendingSchedules() {
        let now = Date()
        for schedule in schedules where schedule.isActive {
            if schedule.scheduledDate <= now {
                onScheduleTriggered?(schedule)
                if let idx = schedules.firstIndex(where: { $0.id == schedule.id }) {
                    schedules[idx].isActive = false
                    saveSchedules()
                }
            }
        }
    }

    private func saveSchedules() {
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadSchedules() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode([TestSchedule].self, from: data) else { return }
        schedules = loaded.filter { $0.isActive && $0.scheduledDate > Date() }
        if !schedules.isEmpty {
            saveSchedules()
        }
    }
}
