import Foundation

nonisolated struct PPSRVINGenerator: Sendable {
    private static let wmis: [String] = [
        "WBA", "WBS", "WB1", "1HG", "JHM", "JMF", "1G1", "2HG",
        "3VW", "SAL", "WDB", "ZAR", "YV1", "KMH", "MNB", "6T1",
        "JN1", "VF1", "WF0", "WAU", "TRU", "WDD", "5YJ", "LJC",
    ]

    private static let validChars: [Character] = Array("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")

    private static let transliteration: [Character: Int] = [
        "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8,
        "J": 1, "K": 2, "L": 3, "M": 4, "N": 5, "P": 7, "R": 9,
        "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9,
        "0": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
    ]

    private static let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]

    static func generate() -> String {
        let wmi = wmis.randomElement()!
        var vin = Array(wmi)

        for _ in 3..<8 {
            vin.append(validChars.randomElement()!)
        }

        vin.append("0")

        let year = Array("MNPRSTUVWXY123456789ABCDEFGHJK")
        vin.append(year.randomElement()!)

        vin.append(validChars.randomElement()!)

        for _ in 11..<17 {
            let digits: [Character] = Array("0123456789")
            vin.append(digits.randomElement()!)
        }

        let checkDigit = calculateCheckDigit(String(vin))
        vin[8] = checkDigit

        return String(vin)
    }

    static func generateBatch(count: Int) -> [String] {
        (0..<count).map { _ in generate() }
    }

    private static func calculateCheckDigit(_ vin: String) -> Character {
        let chars = Array(vin)
        var sum = 0
        for (i, char) in chars.enumerated() {
            let value = transliteration[char] ?? 0
            sum += value * weights[i]
        }
        let remainder = sum % 11
        return remainder == 10 ? "X" : Character(String(remainder))
    }

    static func isValidFormat(_ vin: String) -> Bool {
        let cleaned = vin.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 17 else { return false }
        let invalidChars = CharacterSet(charactersIn: "IOQ")
        return cleaned.unicodeScalars.allSatisfy { !invalidChars.contains($0) }
    }
}
