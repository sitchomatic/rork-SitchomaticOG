import Foundation

@MainActor
class FlowPersistenceService {
    static let shared = FlowPersistenceService()

    private let flowsKey = "recorded_flows_v1"
    private let backupKey = "recorded_flows_backup_v1"
    private let logger = DebugLogger.shared

    func saveFlows(_ flows: [RecordedFlow]) {
        do {
            let data = try JSONEncoder().encode(flows)
            if let existingData = UserDefaults.standard.data(forKey: flowsKey) {
                UserDefaults.standard.set(existingData, forKey: backupKey)
            }
            UserDefaults.standard.set(data, forKey: flowsKey)
            logger.log("FlowPersistence: saved \(flows.count) flows (\(data.count) bytes)", category: .persistence, level: .info, metadata: [
                "flowCount": "\(flows.count)",
                "dataSize": "\(data.count)"
            ])
        } catch {
            logger.logError("FlowPersistence: save failed", error: error, category: .persistence)
            logger.logHealing(category: .persistence, originalError: error.localizedDescription, healingAction: "Attempting individual flow save", succeeded: false)
            for (index, flow) in flows.enumerated() {
                if let singleData = try? JSONEncoder().encode([flow]) {
                    logger.log("FlowPersistence: flow #\(index) '\(flow.name)' encodes OK (\(singleData.count) bytes)", category: .persistence, level: .debug)
                } else {
                    logger.log("FlowPersistence: flow #\(index) '\(flow.name)' FAILS to encode — \(flow.actionCount) actions", category: .persistence, level: .error)
                }
            }
        }
    }

    func loadFlows() -> [RecordedFlow] {
        guard let data = UserDefaults.standard.data(forKey: flowsKey) else {
            logger.log("FlowPersistence: no saved flows found", category: .persistence, level: .debug)
            return []
        }
        do {
            let flows = try JSONDecoder().decode([RecordedFlow].self, from: data)
            logger.log("FlowPersistence: loaded \(flows.count) flows (\(data.count) bytes)", category: .persistence, level: .info)
            return flows
        } catch {
            logger.logError("FlowPersistence: load failed — attempting backup recovery", error: error, category: .persistence)
            if let backupData = UserDefaults.standard.data(forKey: backupKey) {
                do {
                    let backupFlows = try JSONDecoder().decode([RecordedFlow].self, from: backupData)
                    logger.logHealing(category: .persistence, originalError: "Primary flow data corrupted", healingAction: "Recovered \(backupFlows.count) flows from backup", succeeded: true)
                    UserDefaults.standard.set(backupData, forKey: flowsKey)
                    return backupFlows
                } catch {
                    logger.logHealing(category: .persistence, originalError: "Both primary and backup data corrupted", healingAction: "Backup recovery also failed", succeeded: false)
                }
            }
            logger.log("FlowPersistence: all recovery attempts failed — returning empty", category: .persistence, level: .critical)
            return []
        }
    }

    func exportFlow(_ flow: RecordedFlow) -> Data? {
        do {
            let data = try JSONEncoder().encode(flow)
            logger.log("FlowPersistence: exported '\(flow.name)' (\(data.count) bytes)", category: .persistence, level: .info)
            return data
        } catch {
            logger.logError("FlowPersistence: export failed for '\(flow.name)'", error: error, category: .persistence)
            return nil
        }
    }

    func importFlow(from data: Data) -> RecordedFlow? {
        do {
            let flow = try JSONDecoder().decode(RecordedFlow.self, from: data)
            logger.log("FlowPersistence: imported '\(flow.name)' — \(flow.actionCount) actions", category: .persistence, level: .success)
            return flow
        } catch {
            logger.logError("FlowPersistence: import failed (\(data.count) bytes)", error: error, category: .persistence, metadata: [
                "dataSize": "\(data.count)",
                "dataPreview": String(data: data.prefix(100), encoding: .utf8) ?? "non-UTF8"
            ])
            return nil
        }
    }
}
