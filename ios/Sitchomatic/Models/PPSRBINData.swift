import Foundation
import Observation

@Observable
class PPSRBINData {
    let bin: String
    var scheme: String
    var type: String
    var category: String
    var issuer: String
    var country: String
    var countryCode: String
    var isLoaded: Bool

    init(bin: String, scheme: String = "", type: String = "", category: String = "", issuer: String = "", country: String = "", countryCode: String = "", isLoaded: Bool = false) {
        self.bin = bin
        self.scheme = scheme
        self.type = type
        self.category = category
        self.issuer = issuer
        self.country = country
        self.countryCode = countryCode
        self.isLoaded = isLoaded
    }
}
