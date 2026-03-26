import Foundation

nonisolated struct NordLynxAccessKey: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let key: String
    let isPreset: Bool

    static let nick = NordLynxAccessKey(
        id: "nick",
        name: "Nick",
        key: kDefaultNickKey,
        isPreset: true
    )

    static let poli = NordLynxAccessKey(
        id: "poli",
        name: "Poli",
        key: kDefaultPoliKey,
        isPreset: true
    )

    static let presets: [NordLynxAccessKey] = [.nick, .poli]
}
