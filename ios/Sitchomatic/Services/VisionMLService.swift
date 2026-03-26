import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

@MainActor
class VisionMLService {
    static let shared = VisionMLService()

    private let logger = DebugLogger.shared
    private let ciContext = CIContext()
    private var cachedSaliencyResults: [Int: [CGRect]] = [:]

    nonisolated struct OCRElement: Sendable {
        let text: String
        let boundingBox: CGRect
        let confidence: Float
        let normalizedCenter: CGPoint

        var pixelCenter: CGPoint {
            CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        }
    }

    nonisolated struct UIElementDetection: Sendable {
        let elements: [OCRElement]
        let inputFields: [OCRElement]
        let buttons: [OCRElement]
        let labels: [OCRElement]
        let imageSize: CGSize
        let processingTimeMs: Int
    }

    nonisolated struct LoginFieldDetection: Sendable {
        let emailField: FieldHit?
        let passwordField: FieldHit?
        let loginButton: FieldHit?
        let allText: [OCRElement]
        let confidence: Double
        let method: String
        let instanceMaskRegions: [MaskedRegion]
        let saliencyHotspots: [CGRect]
        let aiEnhanced: Bool

        init(emailField: FieldHit?, passwordField: FieldHit?, loginButton: FieldHit?, allText: [OCRElement], confidence: Double, method: String, instanceMaskRegions: [MaskedRegion] = [], saliencyHotspots: [CGRect] = [], aiEnhanced: Bool = false) {
            self.emailField = emailField
            self.passwordField = passwordField
            self.loginButton = loginButton
            self.allText = allText
            self.confidence = confidence
            self.method = method
            self.instanceMaskRegions = instanceMaskRegions
            self.saliencyHotspots = saliencyHotspots
            self.aiEnhanced = aiEnhanced
        }
    }

    nonisolated struct FieldHit: Sendable {
        let label: String
        let boundingBox: CGRect
        let pixelCoordinate: CGPoint
        let confidence: Float
        let nearbyText: String?
    }

    nonisolated struct MaskedRegion: Sendable {
        let instanceIndex: Int
        let boundingBox: CGRect
        let pixelArea: Int
        let overlappingText: [String]
        let predictedType: String
    }

    nonisolated struct SaliencyResult: Sendable {
        let hotspots: [CGRect]
        let primaryFocus: CGRect?
        let processingTimeMs: Int
    }

    func recognizeAllText(in image: UIImage) async -> [OCRElement] {
        guard let cgImage = image.cgImage else { return [] }
        let startTime = Date()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            logger.logError("VisionML: OCR perform failed", error: error, category: .automation)
            return []
        }

        guard let observations = request.results else { return [] }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        var elements: [OCRElement] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }

            let box = observation.boundingBox
            let pixelRect = CGRect(
                x: box.origin.x * imageSize.width,
                y: (1 - box.origin.y - box.height) * imageSize.height,
                width: box.width * imageSize.width,
                height: box.height * imageSize.height
            )

            let normalizedCenter = CGPoint(
                x: box.origin.x + box.width / 2,
                y: 1 - (box.origin.y + box.height / 2)
            )

            elements.append(OCRElement(
                text: candidate.string,
                boundingBox: pixelRect,
                confidence: candidate.confidence,
                normalizedCenter: normalizedCenter
            ))
        }

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        logger.log("VisionML: OCR found \(elements.count) text elements in \(elapsed)ms", category: .automation, level: .debug)

        return elements
    }

    func detectLoginElements(in image: UIImage, viewportSize: CGSize) async -> LoginFieldDetection {
        let startTime = Date()
        let allText = await recognizeAllText(in: image)

        guard let cgImage = image.cgImage else {
            return LoginFieldDetection(emailField: nil, passwordField: nil, loginButton: nil, allText: allText, confidence: 0, method: "vision_ocr_failed")
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scaleX = viewportSize.width / imageSize.width
        let scaleY = viewportSize.height / imageSize.height

        var emailField: FieldHit?
        var passwordField: FieldHit?
        var loginButton: FieldHit?

        let emailKeywords = ["email", "e-mail", "username", "user name", "login", "email address"]
        let passwordKeywords = ["password", "pass", "pin", "secret"]
        let loginButtonKeywords = ["log in", "login", "sign in", "signin", "submit", "enter", "go"]

        for element in allText {
            let lower = element.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            for keyword in emailKeywords {
                if lower.contains(keyword) && emailField == nil {
                    let inputCoord = estimateInputFieldBelow(
                        labelBox: element.boundingBox,
                        imageSize: imageSize,
                        scaleX: scaleX,
                        scaleY: scaleY
                    )
                    emailField = FieldHit(
                        label: element.text,
                        boundingBox: element.boundingBox,
                        pixelCoordinate: inputCoord,
                        confidence: element.confidence,
                        nearbyText: lower
                    )
                    break
                }
            }

            for keyword in passwordKeywords {
                if lower.contains(keyword) && passwordField == nil {
                    let inputCoord = estimateInputFieldBelow(
                        labelBox: element.boundingBox,
                        imageSize: imageSize,
                        scaleX: scaleX,
                        scaleY: scaleY
                    )
                    passwordField = FieldHit(
                        label: element.text,
                        boundingBox: element.boundingBox,
                        pixelCoordinate: inputCoord,
                        confidence: element.confidence,
                        nearbyText: lower
                    )
                    break
                }
            }

            for keyword in loginButtonKeywords {
                if lower == keyword || (lower.contains(keyword) && lower.count < 20) {
                    if loginButton == nil || element.confidence > (loginButton?.confidence ?? 0) {
                        let center = CGPoint(
                            x: element.boundingBox.midX * scaleX,
                            y: element.boundingBox.midY * scaleY
                        )
                        loginButton = FieldHit(
                            label: element.text,
                            boundingBox: element.boundingBox,
                            pixelCoordinate: center,
                            confidence: element.confidence,
                            nearbyText: lower
                        )
                    }
                }
            }
        }

        let foundCount = [emailField, passwordField, loginButton].compactMap { $0 }.count
        let confidence = Double(foundCount) / 3.0

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        logger.log("VisionML: login detection — email:\(emailField != nil) pass:\(passwordField != nil) btn:\(loginButton != nil) confidence:\(String(format: "%.0f%%", confidence * 100)) in \(elapsed)ms", category: .automation, level: foundCount >= 2 ? .success : .warning)

        return LoginFieldDetection(
            emailField: emailField,
            passwordField: passwordField,
            loginButton: loginButton,
            allText: allText,
            confidence: confidence,
            method: "vision_ocr"
        )
    }

    func findTextOnScreen(_ searchText: String, in image: UIImage, viewportSize: CGSize) async -> FieldHit? {
        let allText = await recognizeAllText(in: image)

        guard let cgImage = image.cgImage else { return nil }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scaleX = viewportSize.width / imageSize.width
        let scaleY = viewportSize.height / imageSize.height
        let searchLower = searchText.lowercased()

        var bestMatch: (element: OCRElement, score: Double)?

        for element in allText {
            let elementLower = element.text.lowercased()

            if elementLower == searchLower {
                let center = CGPoint(
                    x: element.boundingBox.midX * scaleX,
                    y: element.boundingBox.midY * scaleY
                )
                return FieldHit(
                    label: element.text,
                    boundingBox: element.boundingBox,
                    pixelCoordinate: center,
                    confidence: element.confidence,
                    nearbyText: elementLower
                )
            }

            if elementLower.contains(searchLower) {
                let score = Double(searchLower.count) / Double(elementLower.count) * Double(element.confidence)
                if bestMatch == nil || score > (bestMatch?.score ?? 0) {
                    bestMatch = (element, score)
                }
            }
        }

        if let match = bestMatch {
            let center = CGPoint(
                x: match.element.boundingBox.midX * scaleX,
                y: match.element.boundingBox.midY * scaleY
            )
            return FieldHit(
                label: match.element.text,
                boundingBox: match.element.boundingBox,
                pixelCoordinate: center,
                confidence: match.element.confidence,
                nearbyText: match.element.text.lowercased()
            )
        }

        return nil
    }

    nonisolated enum DisabledDetectionType: String, Sendable {
        case permDisabled
        case tempDisabled
        case smsDetected
        case none
    }

    func detectSuccessIndicators(in image: UIImage) async -> (welcomeFound: Bool, errorFound: Bool, context: String?) {
        let allText = await recognizeAllText(in: image)

        let successTerms = ["dashboard", "my account", "balance", "deposit", "logout", "log out"]
        let errorTerms = ["incorrect", "invalid", "error", "failed", "wrong", "disabled", "blocked", "suspended", "locked"]

        var welcomeFound = false
        var errorFound = false
        var context: String?

        for element in allText {
            let lower = element.text.lowercased()
            for term in successTerms {
                if lower.contains(term) {
                    welcomeFound = true
                    context = element.text
                    break
                }
            }
            for term in errorTerms {
                if lower.contains(term) {
                    errorFound = true
                    if context == nil { context = element.text }
                    break
                }
            }
        }

        return (welcomeFound, errorFound, context)
    }

    func detectDisabledAccount(in image: UIImage) async -> (type: DisabledDetectionType, matchedText: String?, allOCRText: String) {
        let allText = await recognizeAllText(in: image)
        let fullText = allText.map { $0.text }.joined(separator: " ")
        let fullLower = fullText.lowercased()

        let permDisabledPhrases = [
            "account has been disabled", "your account has been disabled",
            "account is disabled", "has been disabled",
            "account has been suspended", "has been suspended",
            "account has been blocked", "has been blocked",
            "account has been deactivated", "has been deactivated",
            "permanently banned", "permanently disabled",
            "account is closed", "self-excluded",
            "account is locked", "your account is locked",
            "account is restricted", "blacklisted",
            "contact customer service", "please, contact customer",
        ]

        let tempDisabledPhrases = [
            "temporarily disabled", "temporarily suspended",
            "temporarily blocked", "temporarily locked",
            "too many attempts", "too many login attempts",
            "too many failed", "try again later",
            "try again in", "account temporarily",
            "locked for", "wait before",
            "exceeded login attempts", "login attempts exceeded",
            "multiple failed attempts",
        ]

        let smsNotificationPhrases = [
            "sms", "text message", "verification code", "verify your phone",
            "send code", "sent a code", "enter the code", "phone verification",
            "mobile verification", "confirm your number", "code sent",
            "enter code", "security code sent", "check your phone"
        ]
        for phrase in smsNotificationPhrases {
            if fullLower.contains(phrase) {
                let matchedLine = allText.first { $0.text.lowercased().contains(phrase) }?.text ?? phrase
                logger.log("VisionML: SMS NOTIFICATION detected via OCR — '\(phrase)'", category: .automation, level: .critical)
                return (.smsDetected, matchedLine, fullText)
            }
        }

        for phrase in tempDisabledPhrases {
            if fullLower.contains(phrase) {
                let matchedLine = allText.first { $0.text.lowercased().contains(phrase) }?.text ?? phrase
                logger.log("VisionML: TEMP DISABLED detected via OCR — '\(phrase)'", category: .automation, level: .critical)
                return (.tempDisabled, matchedLine, fullText)
            }
        }

        for phrase in permDisabledPhrases {
            if fullLower.contains(phrase) {
                let matchedLine = allText.first { $0.text.lowercased().contains(phrase) }?.text ?? phrase
                logger.log("VisionML: PERM DISABLED detected via OCR — '\(phrase)'", category: .automation, level: .critical)
                return (.permDisabled, matchedLine, fullText)
            }
        }

        var disabledScore = 0
        let weakSignals: [(String, Int)] = [
            ("disabled", 30), ("suspended", 30), ("blocked", 25),
            ("banned", 30), ("locked", 20), ("restricted", 20),
            ("deactivated", 30), ("contact support", 15),
            ("contact customer", 20),
        ]
        var matchedWeak: String?
        for (term, weight) in weakSignals {
            if fullLower.contains(term) {
                disabledScore += weight
                if matchedWeak == nil {
                    matchedWeak = allText.first { $0.text.lowercased().contains(term) }?.text
                }
            }
        }

        if disabledScore >= 40 {
            logger.log("VisionML: PERM DISABLED detected via weak signal scoring (\(disabledScore))", category: .automation, level: .critical)
            return (.permDisabled, matchedWeak, fullText)
        }

        return (.none, nil, fullText)
    }

    func detectRectangularRegions(in image: UIImage) async -> [CGRect] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.05
        request.maximumObservations = 20

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            logger.logError("VisionML: rectangle detection failed", error: error, category: .automation)
            return []
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox
            return CGRect(
                x: box.origin.x * imageSize.width,
                y: (1 - box.origin.y - box.height) * imageSize.height,
                width: box.width * imageSize.width,
                height: box.height * imageSize.height
            )
        }
    }

    // MARK: - Instance Segmentation (Foreground Mask)

    func detectForegroundInstances(in image: UIImage) async -> [MaskedRegion] {
        guard let cgImage = image.cgImage else { return [] }
        let startTime = Date()

        let ciImage = CIImage(cgImage: cgImage)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: ciImage)

        do {
            try handler.perform([request])
        } catch {
            logger.logError("VisionML: instance mask failed", error: error, category: .automation)
            return []
        }

        guard let result = request.results?.first else { return [] }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        var regions: [MaskedRegion] = []

        for (index, instance) in result.allInstances.enumerated() {
            do {
                let maskBuffer = try result.generateScaledMaskForImage(forInstances: [instance], from: handler)
                let maskCI = CIImage(cvPixelBuffer: maskBuffer)
                let maskExtent = maskCI.extent

                let normalizedBox = CGRect(
                    x: maskExtent.origin.x / CGFloat(cgImage.width),
                    y: maskExtent.origin.y / CGFloat(cgImage.height),
                    width: maskExtent.width / CGFloat(cgImage.width),
                    height: maskExtent.height / CGFloat(cgImage.height)
                )

                let pixelBox = CGRect(
                    x: normalizedBox.origin.x * imageSize.width,
                    y: (1 - normalizedBox.origin.y - normalizedBox.height) * imageSize.height,
                    width: normalizedBox.width * imageSize.width,
                    height: normalizedBox.height * imageSize.height
                )

                let area = Int(pixelBox.width * pixelBox.height)

                regions.append(MaskedRegion(
                    instanceIndex: index,
                    boundingBox: pixelBox,
                    pixelArea: area,
                    overlappingText: [],
                    predictedType: classifyRegion(box: pixelBox, imageSize: imageSize)
                ))
            } catch {
                logger.log("VisionML: mask generation failed for instance \(index)", category: .automation, level: .warning)
            }
        }

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        logger.log("VisionML: detected \(regions.count) foreground instances in \(elapsed)ms", category: .automation, level: .debug)
        return regions
    }

    // MARK: - Saliency Detection

    func detectSaliency(in image: UIImage) async -> SaliencyResult {
        guard let cgImage = image.cgImage else {
            return SaliencyResult(hotspots: [], primaryFocus: nil, processingTimeMs: 0)
        }
        let startTime = Date()

        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([attentionRequest, objectnessRequest])
        } catch {
            logger.logError("VisionML: saliency detection failed", error: error, category: .automation)
            return SaliencyResult(hotspots: [], primaryFocus: nil, processingTimeMs: 0)
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        var hotspots: [CGRect] = []

        if let attentionResult = attentionRequest.results?.first {
            for region in attentionResult.salientObjects ?? [] {
                let box = region.boundingBox
                let pixelRect = CGRect(
                    x: box.origin.x * imageSize.width,
                    y: (1 - box.origin.y - box.height) * imageSize.height,
                    width: box.width * imageSize.width,
                    height: box.height * imageSize.height
                )
                hotspots.append(pixelRect)
            }
        }

        if let objectResult = objectnessRequest.results?.first {
            for region in objectResult.salientObjects ?? [] {
                let box = region.boundingBox
                let pixelRect = CGRect(
                    x: box.origin.x * imageSize.width,
                    y: (1 - box.origin.y - box.height) * imageSize.height,
                    width: box.width * imageSize.width,
                    height: box.height * imageSize.height
                )
                hotspots.append(pixelRect)
            }
        }

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        let primaryFocus = hotspots.max(by: { $0.width * $0.height < $1.width * $1.height })
        logger.log("VisionML: saliency found \(hotspots.count) hotspots in \(elapsed)ms", category: .automation, level: .debug)

        return SaliencyResult(hotspots: hotspots, primaryFocus: primaryFocus, processingTimeMs: elapsed)
    }

    // MARK: - Deep Login Detection (OCR + Instance Mask + Saliency + AI)

    func deepDetectLoginElements(in image: UIImage, viewportSize: CGSize) async -> LoginFieldDetection {
        let startTime = Date()

        async let ocrTask = recognizeAllText(in: image)
        async let instanceTask = detectForegroundInstances(in: image)
        async let saliencyTask = detectSaliency(in: image)

        let allText = await ocrTask
        let instances = await instanceTask
        let saliency = await saliencyTask

        guard let cgImage = image.cgImage else {
            return LoginFieldDetection(emailField: nil, passwordField: nil, loginButton: nil, allText: allText, confidence: 0, method: "deep_vision_failed")
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scaleX = viewportSize.width / imageSize.width
        let scaleY = viewportSize.height / imageSize.height

        let enrichedInstances = instances.map { region -> MaskedRegion in
            var overlapping: [String] = []
            for element in allText {
                if region.boundingBox.intersects(element.boundingBox) {
                    overlapping.append(element.text)
                }
            }
            return MaskedRegion(
                instanceIndex: region.instanceIndex,
                boundingBox: region.boundingBox,
                pixelArea: region.pixelArea,
                overlappingText: overlapping,
                predictedType: region.predictedType
            )
        }

        var emailField: FieldHit?
        var passwordField: FieldHit?
        var loginButton: FieldHit?

        let emailKeywords = ["email", "e-mail", "username", "user name", "login", "email address"]
        let passwordKeywords = ["password", "pass", "pin", "secret"]
        let loginButtonKeywords = ["log in", "login", "sign in", "signin", "submit", "enter", "go"]

        for element in allText {
            let lower = element.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            for keyword in emailKeywords {
                if lower.contains(keyword) && emailField == nil {
                    let inputCoord = estimateInputFieldBelow(labelBox: element.boundingBox, imageSize: imageSize, scaleX: scaleX, scaleY: scaleY)
                    emailField = FieldHit(label: element.text, boundingBox: element.boundingBox, pixelCoordinate: inputCoord, confidence: element.confidence, nearbyText: lower)
                    break
                }
            }

            for keyword in passwordKeywords {
                if lower.contains(keyword) && passwordField == nil {
                    let inputCoord = estimateInputFieldBelow(labelBox: element.boundingBox, imageSize: imageSize, scaleX: scaleX, scaleY: scaleY)
                    passwordField = FieldHit(label: element.text, boundingBox: element.boundingBox, pixelCoordinate: inputCoord, confidence: element.confidence, nearbyText: lower)
                    break
                }
            }

            for keyword in loginButtonKeywords {
                if lower == keyword || (lower.contains(keyword) && lower.count < 20) {
                    if loginButton == nil || element.confidence > (loginButton?.confidence ?? 0) {
                        let center = CGPoint(x: element.boundingBox.midX * scaleX, y: element.boundingBox.midY * scaleY)
                        loginButton = FieldHit(label: element.text, boundingBox: element.boundingBox, pixelCoordinate: center, confidence: element.confidence, nearbyText: lower)
                    }
                }
            }
        }

        if loginButton == nil {
            for region in enrichedInstances {
                let isButtonShaped = region.boundingBox.width > region.boundingBox.height * 2
                let isInSalientZone = saliency.hotspots.contains { $0.intersects(region.boundingBox) }
                let hasButtonText = region.overlappingText.contains { text in
                    loginButtonKeywords.contains { text.lowercased().contains($0) }
                }

                if (isButtonShaped && isInSalientZone) || hasButtonText {
                    let center = CGPoint(
                        x: region.boundingBox.midX * scaleX,
                        y: region.boundingBox.midY * scaleY
                    )
                    let label = region.overlappingText.first ?? "predicted_button"
                    loginButton = FieldHit(label: label, boundingBox: region.boundingBox, pixelCoordinate: center, confidence: 0.6, nearbyText: label.lowercased())
                    break
                }
            }
        }

        var aiEnhanced = false
        let aiService = OnDeviceAIService.shared
        if aiService.isAvailable {
            let ocrTexts = allText.map { $0.text }
            if let mapping = await aiService.mapOCRToFields(ocrTexts: ocrTexts) {
                aiEnhanced = true

                if emailField == nil {
                    for aiLabel in mapping.emailLabels {
                        if let match = allText.first(where: { $0.text.lowercased().contains(aiLabel.lowercased()) }) {
                            let coord = estimateInputFieldBelow(labelBox: match.boundingBox, imageSize: imageSize, scaleX: scaleX, scaleY: scaleY)
                            emailField = FieldHit(label: match.text, boundingBox: match.boundingBox, pixelCoordinate: coord, confidence: match.confidence * 0.8, nearbyText: aiLabel)
                            break
                        }
                    }
                }

                if passwordField == nil {
                    for aiLabel in mapping.passwordLabels {
                        if let match = allText.first(where: { $0.text.lowercased().contains(aiLabel.lowercased()) }) {
                            let coord = estimateInputFieldBelow(labelBox: match.boundingBox, imageSize: imageSize, scaleX: scaleX, scaleY: scaleY)
                            passwordField = FieldHit(label: match.text, boundingBox: match.boundingBox, pixelCoordinate: coord, confidence: match.confidence * 0.8, nearbyText: aiLabel)
                            break
                        }
                    }
                }

                if loginButton == nil {
                    for aiLabel in mapping.buttonLabels {
                        if let match = allText.first(where: { $0.text.lowercased().contains(aiLabel.lowercased()) }) {
                            let center = CGPoint(x: match.boundingBox.midX * scaleX, y: match.boundingBox.midY * scaleY)
                            loginButton = FieldHit(label: match.text, boundingBox: match.boundingBox, pixelCoordinate: center, confidence: match.confidence * 0.8, nearbyText: aiLabel)
                            break
                        }
                    }
                }
            }
        }

        let foundCount = [emailField, passwordField, loginButton].compactMap { $0 }.count
        let confidence = Double(foundCount) / 3.0

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        logger.log("VisionML DEEP: email:\(emailField != nil) pass:\(passwordField != nil) btn:\(loginButton != nil) instances:\(enrichedInstances.count) saliency:\(saliency.hotspots.count) ai:\(aiEnhanced) conf:\(String(format: "%.0f%%", confidence * 100)) in \(elapsed)ms", category: .automation, level: foundCount >= 2 ? .success : .warning)

        return LoginFieldDetection(
            emailField: emailField,
            passwordField: passwordField,
            loginButton: loginButton,
            allText: allText,
            confidence: confidence,
            method: aiEnhanced ? "deep_vision_ai" : "deep_vision_mask_saliency",
            instanceMaskRegions: enrichedInstances,
            saliencyHotspots: saliency.hotspots,
            aiEnhanced: aiEnhanced
        )
    }

    // MARK: - Region Classification

    private func classifyRegion(box: CGRect, imageSize: CGSize) -> String {
        let widthRatio = box.width / imageSize.width
        let heightRatio = box.height / imageSize.height
        let aspectRatio = box.width / max(box.height, 1)

        if widthRatio > 0.4 && heightRatio < 0.08 && aspectRatio > 4 {
            return "input_field"
        }
        if widthRatio > 0.2 && widthRatio < 0.6 && heightRatio < 0.06 && aspectRatio > 2.5 {
            return "button"
        }
        if widthRatio < 0.15 && heightRatio < 0.04 {
            return "label"
        }
        if widthRatio > 0.8 && heightRatio > 0.1 {
            return "banner"
        }
        return "unknown"
    }

    func clearSaliencyCache() {
        cachedSaliencyResults.removeAll()
    }

    private func estimateInputFieldBelow(labelBox: CGRect, imageSize: CGSize, scaleX: CGFloat, scaleY: CGFloat) -> CGPoint {
        let estimatedInputY = labelBox.maxY + labelBox.height * 0.8
        let centerX = labelBox.midX
        return CGPoint(
            x: centerX * scaleX,
            y: estimatedInputY * scaleY
        )
    }

    func buildVisionCalibration(from detection: LoginFieldDetection, forURL url: String) -> LoginCalibrationService.URLCalibration {
        var emailMapping: LoginCalibrationService.ElementMapping?
        if let ef = detection.emailField {
            emailMapping = LoginCalibrationService.ElementMapping(
                coordinates: ef.pixelCoordinate,
                placeholder: ef.nearbyText,
                nearbyText: ef.label
            )
        }

        var passwordMapping: LoginCalibrationService.ElementMapping?
        if let pf = detection.passwordField {
            passwordMapping = LoginCalibrationService.ElementMapping(
                coordinates: pf.pixelCoordinate,
                placeholder: pf.nearbyText,
                nearbyText: pf.label
            )
        }

        var buttonMapping: LoginCalibrationService.ElementMapping?
        if let lb = detection.loginButton {
            buttonMapping = LoginCalibrationService.ElementMapping(
                coordinates: lb.pixelCoordinate,
                nearbyText: lb.label
            )
        }

        return LoginCalibrationService.URLCalibration(
            urlPattern: url,
            emailField: emailMapping,
            passwordField: passwordMapping,
            loginButton: buttonMapping,
            notes: "Vision ML auto-calibrated (confidence: \(String(format: "%.0f%%", detection.confidence * 100)))"
        )
    }
}
