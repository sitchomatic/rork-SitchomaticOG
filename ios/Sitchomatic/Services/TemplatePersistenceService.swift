import Foundation

@MainActor
class TemplatePersistenceService {
    static let shared = TemplatePersistenceService()

    private let templatesKey = "automation_templates_v1"

    func saveTemplates(_ templates: [AutomationTemplate]) {
        let custom = templates.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: templatesKey)
        }
    }

    func loadTemplates() -> [AutomationTemplate] {
        var all = AutomationTemplate.builtInTemplates
        if let data = UserDefaults.standard.data(forKey: templatesKey),
           let custom = try? JSONDecoder().decode([AutomationTemplate].self, from: data) {
            all.append(contentsOf: custom.map { template in
                var normalized = template
                normalized.settings = normalized.settings.normalizedTimeouts()
                return normalized
            })
        }
        return all
    }

    func loadCustomTemplates() -> [AutomationTemplate] {
        guard let data = UserDefaults.standard.data(forKey: templatesKey),
              let custom = try? JSONDecoder().decode([AutomationTemplate].self, from: data) else {
            return []
        }
        return custom.map { template in
            var normalized = template
            normalized.settings = normalized.settings.normalizedTimeouts()
            return normalized
        }
    }
}
