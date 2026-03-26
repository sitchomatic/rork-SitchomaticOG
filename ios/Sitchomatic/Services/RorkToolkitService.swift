import Foundation

nonisolated struct RorkToolkitMessage: Codable, Sendable {
    let role: String
    let content: String
}

nonisolated struct RorkToolkitTextRequest: Codable, Sendable {
    let messages: [RorkToolkitMessage]
}

nonisolated struct RorkToolkitTextResponse: Codable, Sendable {
    let text: String?
    let error: String?
}

@MainActor
class RorkToolkitService {
    static let shared = RorkToolkitService()

    private let logger = DebugLogger.shared
    private var baseURL: String {
        let url = (Bundle.main.infoDictionary?["EXPO_PUBLIC_TOOLKIT_URL"] as? String) ?? ""
        if url.isEmpty { return "https://toolkit.rork.com" }
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    func generateText(systemPrompt: String, userPrompt: String) async -> String? {
        let endpoint = "\(baseURL)/agent/chat"
        guard let url = URL(string: endpoint) else {
            logger.log("RorkToolkit: invalid URL \(endpoint)", category: .automation, level: .error)
            return nil
        }

        let messages = [
            RorkToolkitMessage(role: "system", content: systemPrompt),
            RorkToolkitMessage(role: "user", content: userPrompt)
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            logger.log("RorkToolkit: failed to serialize request body", category: .automation, level: .error)
            return nil
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if httpResponse.statusCode != 200 {
                logger.log("RorkToolkit: HTTP \(httpResponse.statusCode)", category: .automation, level: .warning)
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let text = json["text"] as? String { return text }
                if let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    return content
                }
            }

            return String(data: data, encoding: .utf8)
        } catch {
            logger.log("RorkToolkit: request failed — \(error.localizedDescription)", category: .automation, level: .warning)
            return nil
        }
    }
}
