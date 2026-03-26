import Foundation
import Observation

nonisolated enum CardBrand: String, Sendable, Codable {
    case visa = "Visa"
    case mastercard = "Mastercard"
    case amex = "Amex"
    case jcb = "JCB"
    case discover = "Discover"
    case dinersClub = "Diners"
    case unionPay = "UnionPay"
    case unknown = "Card"

    var iconName: String {
        switch self {
        case .visa: "v.circle.fill"
        case .mastercard: "m.circle.fill"
        case .amex: "a.circle.fill"
        case .jcb: "j.circle.fill"
        case .discover: "d.circle.fill"
        case .dinersClub: "d.circle.fill"
        case .unionPay: "u.circle.fill"
        case .unknown: "creditcard.fill"
        }
    }

    var brandColor: String {
        switch self {
        case .visa: "blue"
        case .mastercard: "orange"
        case .amex: "green"
        case .jcb: "red"
        case .discover: "purple"
        case .dinersClub: "indigo"
        case .unionPay: "teal"
        case .unknown: "gray"
        }
    }

    static func detect(_ number: String) -> CardBrand {
        let n = number.filter { $0.isNumber }
        if n.hasPrefix("4") { return .visa }
        if n.hasPrefix("34") || n.hasPrefix("37") { return .amex }
        if n.hasPrefix("35") { return .jcb }
        if n.hasPrefix("36") || n.hasPrefix("38") || n.hasPrefix("300") || n.hasPrefix("301") || n.hasPrefix("302") || n.hasPrefix("303") || n.hasPrefix("304") || n.hasPrefix("305") { return .dinersClub }
        if n.hasPrefix("6011") || n.hasPrefix("65") || n.hasPrefix("644") || n.hasPrefix("645") || n.hasPrefix("646") || n.hasPrefix("647") || n.hasPrefix("648") || n.hasPrefix("649") { return .discover }
        if n.hasPrefix("62") { return .unionPay }
        if n.hasPrefix("5") || n.hasPrefix("2") { return .mastercard }
        return .unknown
    }
}

nonisolated enum CardStatus: String, Sendable, Codable {
    case untested = "Untested"
    case testing = "Testing"
    case working = "Working"
    case dead = "Dead"
}

@Observable
class PPSRCard: Identifiable {
    let id: String
    let number: String
    let expiryMonth: String
    let expiryYear: String
    let cvv: String
    let brand: CardBrand
    private(set) var addedAt: Date
    var status: CardStatus
    var testResults: [PPSRTestResult]
    var binData: PPSRBINData?

    var binPrefix: String {
        String(number.prefix(6))
    }

    var displayNumber: String {
        number
    }

    var pipeFormat: String {
        "\(number)|\(expiryMonth)|\(expiryYear)|\(cvv)"
    }

    var formattedExpiry: String {
        "\(expiryMonth)/\(expiryYear)"
    }

    var isExpired: Bool {
        let cal = Calendar.current
        let now = Date()
        let currentYear = cal.component(.year, from: now) % 100
        let currentMonth = cal.component(.month, from: now)
        guard let cardMonth = Int(expiryMonth), let cardYear = Int(expiryYear) else { return true }
        if cardYear < currentYear { return true }
        if cardYear == currentYear && cardMonth < currentMonth { return true }
        return false
    }

    var totalTests: Int { testResults.count }
    var successCount: Int { testResults.filter { $0.success }.count }
    var failureCount: Int { testResults.filter { !$0.success }.count }

    var successRate: Double {
        guard totalTests > 0 else { return 0 }
        return Double(successCount) / Double(totalTests)
    }

    var lastTestedAt: Date? {
        testResults.first?.timestamp
    }

    var lastTestSuccess: Bool? {
        testResults.first?.success
    }

    var countryDisplay: String {
        binData?.country ?? ""
    }

    var issuerDisplay: String {
        binData?.issuer ?? ""
    }

    var cardTypeDisplay: String {
        binData?.type ?? ""
    }

    init(number: String, expiryMonth: String, expiryYear: String, cvv: String, id: String? = nil, addedAt: Date? = nil) {
        self.id = id ?? UUID().uuidString
        self.number = number
        self.expiryMonth = Self.sanitizeTwoDigit(expiryMonth)
        self.expiryYear = Self.sanitizeTwoDigit(expiryYear)
        self.cvv = cvv
        self.brand = CardBrand.detect(number)
        self.addedAt = addedAt ?? Date()
        self.status = .untested
        self.testResults = []
    }

    func recordResult(success: Bool, vin: String, duration: TimeInterval, error: String? = nil) {
        let result = PPSRTestResult(
            success: success,
            vin: vin,
            duration: duration,
            errorMessage: error
        )
        testResults.insert(result, at: 0)

        if success {
            status = .working
        } else {
            status = .dead
        }
    }

    func applyCorrection(success: Bool) {
        if success {
            status = .working
        } else {
            status = .dead
        }
        if let latest = testResults.first {
            let corrected = PPSRTestResult(
                success: success,
                vin: latest.vin,
                duration: latest.duration,
                errorMessage: success ? nil : "Manually marked as fail"
            )
            testResults[0] = corrected
        }
    }

    func loadBINData() async {
        let data = await BINLookupService.shared.lookup(bin: binPrefix)
        binData = data
    }

    static func sanitizeTwoDigit(_ value: String) -> String {
        let digits = value.filter { $0.isNumber }
        if digits.count >= 2 {
            return String(digits.suffix(2))
        } else if digits.count == 1 {
            return "0\(digits)"
        }
        return "00"
    }

    static func smartParse(_ input: String) -> [PPSRCard] {
        let emojiBlocks = splitByCardEmoji(input)
        if emojiBlocks.count > 1 {
            var cards: [PPSRCard] = []
            for block in emojiBlocks {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if let card = parseRichTextBlock(trimmed) {
                    cards.append(card)
                }
            }
            if !cards.isEmpty { return cards }
        }

        if let card = parseRichTextBlock(input) {
            return [card]
        }

        let blocks = input.components(separatedBy: "\n\n")
        if blocks.count > 1 {
            var cards: [PPSRCard] = []
            for block in blocks {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if let card = parseRichTextBlock(trimmed) {
                    cards.append(card)
                    continue
                }
                let blockLines = trimmed.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                for line in blockLines {
                    if let card = parseLine(line) {
                        cards.append(card)
                    }
                }
            }
            if !cards.isEmpty { return cards }
        }

        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var cards: [PPSRCard] = []
        for line in lines {
            if let card = parseLine(line) {
                cards.append(card)
            }
        }
        return cards
    }

    private static func splitByCardEmoji(_ input: String) -> [String] {
        let marker = "\u{1F4B3}"
        let parts = input.components(separatedBy: marker)
        if parts.count <= 1 { return [] }
        return parts.dropFirst().map { marker + $0 }
    }

    static func parseRichTextBlock(_ block: String) -> PPSRCard? {
        let text = block.replacingOccurrences(of: "\r\n", with: "\n")
        let combined = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")

        var ccnum: String?
        var cvv: String?
        var expDate: String?

        let ccnumPatterns = [
            "CCNUM[:\\s]+(\\d{13,19})",
            "CC(?:NUM)?[:#]\\s*(\\d{13,19})",
            "Card\\s*(?:Number|No|#)?[:\\s]+(\\d{13,19})"
        ]
        for pattern in ccnumPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsRange = NSRange(combined.startIndex..., in: combined)
                if let match = regex.firstMatch(in: combined, range: nsRange) {
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: combined) {
                        let digits = String(combined[range])
                        if digits.count >= 13, digits.count <= 19 {
                            ccnum = digits
                            break
                        }
                    }
                }
            }
        }

        let cvvPatterns = [
            "CVV[:\\s]+(\\d{3,4})",
            "CVC[:\\s]+(\\d{3,4})",
            "CVV2[:\\s]+(\\d{3,4})"
        ]
        for pattern in cvvPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsRange = NSRange(combined.startIndex..., in: combined)
                if let match = regex.firstMatch(in: combined, range: nsRange) {
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: combined) {
                        cvv = String(combined[range])
                        break
                    }
                }
            }
        }

        let expPatterns = [
            "EXP(?:\\s+DATE)?[:\\s]+(\\d{1,2}[/\\-]\\d{2,4})",
            "Expiry[:\\s]+(\\d{1,2}[/\\-]\\d{2,4})",
            "Exp[:\\s]+(\\d{1,2}[/\\-]\\d{2,4})"
        ]
        for pattern in expPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsRange = NSRange(combined.startIndex..., in: combined)
                if let match = regex.firstMatch(in: combined, range: nsRange) {
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: combined) {
                        expDate = String(combined[range])
                        break
                    }
                }
            }
        }

        guard let num = ccnum, let cv = cvv, let exp = expDate else { return nil }

        let expParts = exp.components(separatedBy: CharacterSet(charactersIn: "/-"))
        guard expParts.count == 2 else { return nil }
        let month = expParts[0].filter { $0.isNumber }
        let year = expParts[1].filter { $0.isNumber }

        let sanitizedMonth = sanitizeTwoDigit(month)
        guard let monthInt = Int(sanitizedMonth), monthInt >= 1, monthInt <= 12 else { return nil }
        guard cv.count >= 3, cv.count <= 4 else { return nil }

        return PPSRCard(number: num, expiryMonth: sanitizedMonth, expiryYear: sanitizeTwoDigit(year), cvv: cv)
    }

    static func parseCSVData(_ csvText: String, columnMapping: CSVColumnMapping = .auto) -> [PPSRCard] {
        let lines = csvText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        var cards: [PPSRCard] = []
        let startIndex = isHeaderRow(lines[0]) ? 1 : 0

        for i in startIndex..<lines.count {
            let columns = parseCSVLine(lines[i])
            if let card = extractCardFromColumns(columns, mapping: columnMapping) {
                cards.append(card)
            }
        }
        return cards
    }

    private static func isHeaderRow(_ line: String) -> Bool {
        let lower = line.lowercased()
        let headerKeywords = ["card", "number", "expiry", "cvv", "cvc", "exp", "month", "year", "cc"]
        return headerKeywords.contains(where: { lower.contains($0) }) && line.filter({ $0.isNumber }).count < 6
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var columns: [String] = []
        var current = ""
        var inQuotes = false

        let separator: Character = line.contains("\t") ? "\t" : ","

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == separator && !inQuotes {
                columns.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        columns.append(current.trimmingCharacters(in: .whitespaces))
        return columns
    }

    nonisolated enum CSVColumnMapping: Sendable {
        case auto
        case columnsABC
        case columnsCEF
    }

    private static func extractCardFromColumns(_ columns: [String], mapping: CSVColumnMapping) -> PPSRCard? {
        switch mapping {
        case .columnsABC:
            guard columns.count >= 3 else { return nil }
            return buildFromThreeFields(columns[0], columns[1], columns[2])
        case .columnsCEF:
            guard columns.count >= 6 else { return nil }
            return buildFromThreeFields(columns[2], columns[4], columns[5])
        case .auto:
            if columns.count >= 6 {
                if let card = buildFromThreeFields(columns[2], columns[4], columns[5]) {
                    return card
                }
            }
            if columns.count >= 3 {
                if let card = buildFromThreeFields(columns[0], columns[1], columns[2]) {
                    return card
                }
            }
            if columns.count >= 4 {
                let parts = columns.map { $0.trimmingCharacters(in: .whitespaces) }
                if let card = tryBuildCard(from: parts) {
                    return card
                }
            }
            return nil
        }
    }

    private static func buildFromThreeFields(_ cardField: String, _ expiryField: String, _ cvvField: String) -> PPSRCard? {
        let cardNum = cardField.filter { $0.isNumber }
        guard cardNum.count >= 13, cardNum.count <= 19 else { return nil }

        let cvvDigits = cvvField.filter { $0.isNumber }
        guard cvvDigits.count >= 3, cvvDigits.count <= 4 else { return nil }

        var month: String
        var year: String

        let expClean = expiryField.trimmingCharacters(in: .whitespaces)
        if expClean.contains("/") || expClean.contains("-") {
            let parts = expClean.components(separatedBy: CharacterSet(charactersIn: "/-"))
            guard parts.count == 2 else { return nil }
            month = parts[0].filter { $0.isNumber }
            year = parts[1].filter { $0.isNumber }
        } else {
            let digits = expClean.filter { $0.isNumber }
            if digits.count == 4 {
                month = String(digits.prefix(2))
                year = String(digits.suffix(2))
            } else if digits.count == 6 {
                month = String(digits.prefix(2))
                year = String(digits.suffix(2))
            } else {
                return nil
            }
        }

        let sanitizedMonth = sanitizeTwoDigit(month)
        guard let monthInt = Int(sanitizedMonth), monthInt >= 1, monthInt <= 12 else { return nil }

        return PPSRCard(number: cardNum, expiryMonth: sanitizedMonth, expiryYear: sanitizeTwoDigit(year), cvv: String(cvvDigits.prefix(4)))
    }

    static func parseLine(_ line: String) -> PPSRCard? {
        let separators: [String] = ["|", ":", ";", ",", "\t", " "]

        for sep in separators {
            let parts = line.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if parts.count >= 4 {
                if let card = tryBuildCard(from: parts) {
                    return card
                }
            }
        }

        let digits = extractDigitGroups(from: line)
        if digits.count >= 4 {
            if let card = tryBuildCard(from: digits) {
                return card
            }
        }

        return nil
    }

    private static func extractDigitGroups(from line: String) -> [String] {
        var groups: [String] = []
        var current = ""
        for char in line {
            if char.isNumber {
                current.append(char)
            } else {
                if !current.isEmpty {
                    groups.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func tryBuildCard(from parts: [String]) -> PPSRCard? {
        let cardNum = parts[0].filter { $0.isNumber }
        guard cardNum.count >= 13, cardNum.count <= 19 else { return nil }

        var month: String
        var year: String
        var cvv: String

        if parts.count >= 4 {
            let p1 = parts[1].filter { $0.isNumber }
            let p2 = parts[2].filter { $0.isNumber }
            let p3 = parts[3].filter { $0.isNumber }

            if p1.count <= 2 && p2.count <= 4 && p3.count >= 3 {
                month = p1
                year = p2
                cvv = p3
            } else if p1.count == 4 && p1.hasPrefix("20") {
                year = String(p1.suffix(2))
                month = p2
                cvv = p3
            } else if parts[1].contains("/") {
                let expParts = parts[1].components(separatedBy: "/")
                if expParts.count == 2 {
                    month = expParts[0].filter { $0.isNumber }
                    year = expParts[1].filter { $0.isNumber }
                    cvv = p2
                } else {
                    month = p1
                    year = p2
                    cvv = p3
                }
            } else {
                month = p1
                year = p2
                cvv = p3
            }
        } else if parts.count == 3 {
            let expStr = parts[1]
            if expStr.contains("/") {
                let expParts = expStr.components(separatedBy: "/")
                guard expParts.count == 2 else { return nil }
                month = expParts[0].filter { $0.isNumber }
                year = expParts[1].filter { $0.isNumber }
            } else {
                let digits = expStr.filter { $0.isNumber }
                guard digits.count == 4 else { return nil }
                month = String(digits.prefix(2))
                year = String(digits.suffix(2))
            }
            cvv = parts[2].filter { $0.isNumber }
        } else {
            return nil
        }

        let sanitizedMonth = sanitizeTwoDigit(month)
        guard let monthInt = Int(sanitizedMonth), monthInt >= 1, monthInt <= 12 else { return nil }
        guard cvv.count >= 3, cvv.count <= 4 else { return nil }

        let sanitizedYear = sanitizeTwoDigit(year)

        return PPSRCard(number: cardNum, expiryMonth: sanitizedMonth, expiryYear: sanitizedYear, cvv: String(cvv.prefix(4)))
    }

    static func fromPipeFormat(_ input: String) -> PPSRCard? {
        return parseLine(input)
    }
}
