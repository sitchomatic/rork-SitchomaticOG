import Foundation
import Observation

@Observable
@MainActor
class CredentialGroupService {
    static let shared = CredentialGroupService()

    private let persistKey = "credential_groups_v1"
    private let logger = DebugLogger.shared

    var groups: [CredentialGroup] = []
    var activeGroupId: String?

    init() {
        loadGroups()
    }

    func createGroups(from credentialIds: [String], size: GroupSize, colorRotation: [GroupColor] = GroupColor.allCases) {
        let chunks = stride(from: 0, to: credentialIds.count, by: size.rawValue).map {
            Array(credentialIds[$0..<min($0 + size.rawValue, credentialIds.count)])
        }

        for (index, chunk) in chunks.enumerated() {
            let color = colorRotation[index % colorRotation.count]
            let group = CredentialGroup(
                name: "Group \(groups.count + index + 1)",
                color: color,
                credentialIds: chunk
            )
            groups.append(group)
        }

        persistGroups()
        logger.log("CredentialGroups: created \(chunks.count) groups of ~\(size.rawValue) from \(credentialIds.count) credentials", category: .persistence, level: .success)
    }

    func createGroup(name: String, color: GroupColor, credentialIds: [String]) {
        let group = CredentialGroup(name: name, color: color, credentialIds: credentialIds)
        groups.append(group)
        persistGroups()
        logger.log("CredentialGroups: created '\(name)' with \(credentialIds.count) credentials", category: .persistence, level: .success)
    }

    func renameGroup(id: String, name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = name
        persistGroups()
    }

    func recolorGroup(id: String, color: GroupColor) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].color = color
        persistGroups()
    }

    func deleteGroup(id: String) {
        groups.removeAll { $0.id == id }
        if activeGroupId == id { activeGroupId = nil }
        persistGroups()
    }

    func mergeGroups(ids: Set<String>, intoName: String, color: GroupColor) {
        var mergedIds: [String] = []
        for id in ids {
            if let group = groups.first(where: { $0.id == id }) {
                mergedIds.append(contentsOf: group.credentialIds)
            }
        }
        groups.removeAll { ids.contains($0.id) }
        let merged = CredentialGroup(name: intoName, color: color, credentialIds: Array(Set(mergedIds)))
        groups.append(merged)
        persistGroups()
        logger.log("CredentialGroups: merged \(ids.count) groups into '\(intoName)' (\(merged.count) creds)", category: .persistence, level: .success)
    }

    func addCredentials(_ credentialIds: [String], toGroup groupId: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        let existing = Set(groups[idx].credentialIds)
        let newIds = credentialIds.filter { !existing.contains($0) }
        groups[idx].credentialIds.append(contentsOf: newIds)
        persistGroups()
    }

    func removeCredentials(_ credentialIds: Set<String>, fromGroup groupId: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].credentialIds.removeAll { credentialIds.contains($0) }
        persistGroups()
    }

    func groupFor(credentialId: String) -> CredentialGroup? {
        groups.first { $0.credentialIds.contains(credentialId) }
    }

    func credentialIdsForActiveGroup() -> [String]? {
        guard let activeId = activeGroupId,
              let group = groups.first(where: { $0.id == activeId }) else { return nil }
        return group.credentialIds
    }

    func selectGroup(_ id: String?) {
        activeGroupId = id
    }

    func deleteAllGroups() {
        groups.removeAll()
        activeGroupId = nil
        persistGroups()
    }

    private func persistGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadGroups() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let decoded = try? JSONDecoder().decode([CredentialGroup].self, from: data) else { return }
        groups = decoded
    }
}
