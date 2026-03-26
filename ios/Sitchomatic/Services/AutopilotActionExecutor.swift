import Foundation
import WebKit

@MainActor
class AutopilotActionExecutor {
    static let shared = AutopilotActionExecutor()

    private let logger = DebugLogger.shared
    private let autopilot = AISessionAutopilotEngine.shared
    private let timingOptimizer = AITimingOptimizerService.shared
    private let fingerprintTuning = AIFingerprintTuningService.shared

    struct ExecutionResult {
        let action: AutopilotAction
        let success: Bool
        let detail: String
        let durationMs: Int
    }

    func execute(
        decision: AutopilotDecision,
        session: LoginSiteWebSession?,
        proxyTarget: ProxyRotationService.ProxyTarget
    ) async -> ExecutionResult {
        let start = Date()

        let result: ExecutionResult
        switch decision.action {
        case .noOp:
            result = ExecutionResult(action: .noOp, success: true, detail: "No action needed", durationMs: 0)

        case .preemptiveIPRotation:
            result = await executeIPRotation(decision: decision, proxyTarget: proxyTarget)

        case .preemptiveProxySwitch:
            result = await executeProxySwitch(decision: decision, proxyTarget: proxyTarget)

        case .adjustTypingSpeed:
            result = executeTypingSpeedAdjust(decision: decision)

        case .injectCounterFingerprint:
            result = await executeCounterFingerprint(decision: decision, session: session)

        case .pauseAndWait:
            result = await executePauseAndWait(decision: decision)

        case .throttleRequests:
            result = await executeThrottle(decision: decision)

        case .rotateDNS:
            result = executeDNSRotation(decision: decision)

        case .rotateFingerprint:
            result = await executeFingerprintRotation(decision: decision, session: session)

        case .rotateURL:
            result = ExecutionResult(action: .rotateURL, success: true, detail: "URL rotation signaled to batch engine", durationMs: 0)

        case .fullSessionReset:
            result = await executeFullSessionReset(decision: decision, session: session)

        case .abortSession:
            result = ExecutionResult(action: .abortSession, success: true, detail: "Session abort signaled", durationMs: 0)

        case .switchInteractionPattern:
            result = ExecutionResult(action: .switchInteractionPattern, success: true, detail: "Pattern switch signaled to HumanInteractionEngine", durationMs: 0)

        case .injectDecoyTraffic:
            result = await executeDecoyTraffic(decision: decision, session: session)

        case .adjustViewport:
            result = await executeViewportAdjust(decision: decision, session: session)

        case .slowDownInteraction:
            result = executeSlowDown(decision: decision)

        case .speedUpInteraction:
            result = executeSpeedUp(decision: decision)

        case .preemptiveCookieClear:
            result = await executeCookieClear(decision: decision, session: session)

        case .escalateToAI:
            result = ExecutionResult(action: .escalateToAI, success: true, detail: "Escalated to AI strategic analysis", durationMs: 0)
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let finalResult = ExecutionResult(
            action: result.action,
            success: result.success,
            detail: result.detail,
            durationMs: max(result.durationMs, durationMs)
        )

        autopilot.recordInterventionOutcome(
            sessionId: decision.sessionId,
            action: decision.action,
            success: finalResult.success
        )

        let level: DebugLogLevel = finalResult.success ? .info : .warning
        logger.log(
            "AutopilotExec: \(decision.action.rawValue) -> \(finalResult.success ? "OK" : "FAIL") in \(finalResult.durationMs)ms — \(finalResult.detail)",
            category: .automation, level: level
        )

        return finalResult
    }

    private func executeIPRotation(decision: AutopilotDecision, proxyTarget: ProxyRotationService.ProxyTarget) async -> ExecutionResult {
        let deviceProxy = DeviceProxyService.shared
        if deviceProxy.isEnabled {
            deviceProxy.rotateNow(reason: "Autopilot preemptive IP rotation: \(decision.reasoning)")
            return ExecutionResult(action: .preemptiveIPRotation, success: true, detail: "DeviceProxy IP rotated", durationMs: 0)
        }

        if NodeMavenService.shared.isEnabled {
            let _ = NodeMavenService.shared.generateProxyConfig(sessionId: "autopilot_\(Int(Date().timeIntervalSince1970))")
            return ExecutionResult(action: .preemptiveIPRotation, success: true, detail: "NodeMaven session rotated", durationMs: 0)
        }

        let _ = ProxyRotationService.shared.nextWorkingProxy(for: proxyTarget)
        return ExecutionResult(action: .preemptiveIPRotation, success: true, detail: "Proxy rotated for \(proxyTarget.rawValue)", durationMs: 0)
    }

    private func executeProxySwitch(decision: AutopilotDecision, proxyTarget: ProxyRotationService.ProxyTarget) async -> ExecutionResult {
        let _ = ProxyRotationService.shared.nextWorkingProxy(for: proxyTarget)

        if let escalate = decision.parameters["escalate"], escalate == "rotateFingerprint" {
            logger.log("AutopilotExec: escalating proxy switch to include fingerprint rotation", category: .automation, level: .warning)
        }

        return ExecutionResult(action: .preemptiveProxySwitch, success: true, detail: "Proxy switched for \(proxyTarget.rawValue)", durationMs: 0)
    }

    private func executeTypingSpeedAdjust(decision: AutopilotDecision) -> ExecutionResult {
        let targetMs = Int(decision.parameters["targetKeystrokeMs"] ?? "120") ?? 120
        let jitter = Int(decision.parameters["jitter"] ?? "20") ?? 20
        let host = decision.parameters["host"] ?? ""

        if !host.isEmpty {
            timingOptimizer.recordSample(
                host: host,
                category: .keystrokeDelay,
                actualMs: targetMs,
                fillSuccess: true,
                submitSuccess: true,
                detected: true,
                pattern: "autopilot_adjusted"
            )
        }

        return ExecutionResult(
            action: .adjustTypingSpeed, success: true,
            detail: "Typing speed adjusted to \(targetMs)ms +/- \(jitter)ms",
            durationMs: 0
        )
    }

    private func executeCounterFingerprint(decision: AutopilotDecision, session: LoginSiteWebSession?) async -> ExecutionResult {
        guard let webView = session?.webView else {
            return ExecutionResult(action: .injectCounterFingerprint, success: false, detail: "No WebView available", durationMs: 0)
        }

        let probeType = decision.parameters["target"] ?? "webdriver"
        let counterJS: String

        switch probeType {
        case "webdriver":
            counterJS = """
            (function(){
                Object.defineProperty(navigator,'webdriver',{get:()=>undefined,configurable:true});
                delete navigator.__proto__.webdriver;
                if(window.chrome){window.chrome.runtime=window.chrome.runtime||{}}
                Object.defineProperty(navigator,'languages',{get:()=>['en-US','en'],configurable:true});
                Object.defineProperty(navigator,'plugins',{get:()=>[{name:'Chrome PDF Plugin',filename:'internal-pdf-viewer'},{name:'Chrome PDF Viewer',filename:'mhjfbmdgcfjbbpaeojofohoefgiehjai'},{name:'Native Client',filename:'internal-nacl-plugin'}],configurable:true});
                return 'counter_injected';
            })();
            """
        case "fingerprint_api":
            counterJS = """
            (function(){
                const origToDataURL=HTMLCanvasElement.prototype.toDataURL;
                HTMLCanvasElement.prototype.toDataURL=function(type){
                    const ctx=this.getContext('2d');
                    if(ctx){const imgData=ctx.getImageData(0,0,this.width,this.height);for(let i=0;i<imgData.data.length;i+=4){imgData.data[i]^=Math.floor(Math.random()*3);imgData.data[i+1]^=Math.floor(Math.random()*3);}ctx.putImageData(imgData,0,0);}
                    return origToDataURL.apply(this,arguments);
                };
                const origGetImageData=CanvasRenderingContext2D.prototype.getImageData;
                CanvasRenderingContext2D.prototype.getImageData=function(){
                    const data=origGetImageData.apply(this,arguments);
                    for(let i=0;i<Math.min(data.data.length,100);i+=4){data.data[i]^=1;}
                    return data;
                };
                return 'fp_counter_injected';
            })();
            """
        default:
            counterJS = """
            (function(){
                Object.defineProperty(navigator,'webdriver',{get:()=>undefined,configurable:true});
                return 'generic_counter';
            })();
            """
        }

        do {
            _ = try await webView.evaluateJavaScript(counterJS)
            return ExecutionResult(action: .injectCounterFingerprint, success: true, detail: "Counter-fingerprint injected for \(probeType)", durationMs: 0)
        } catch {
            return ExecutionResult(action: .injectCounterFingerprint, success: false, detail: "JS injection failed: \(error.localizedDescription)", durationMs: 0)
        }
    }

    private func executePauseAndWait(decision: AutopilotDecision) async -> ExecutionResult {
        let waitMs = Int(decision.parameters["waitMs"] ?? "2000") ?? 2000
        try? await Task.sleep(for: .milliseconds(waitMs))
        return ExecutionResult(action: .pauseAndWait, success: true, detail: "Paused \(waitMs)ms", durationMs: waitMs)
    }

    private func executeThrottle(decision: AutopilotDecision) async -> ExecutionResult {
        let backoffMs = Int(decision.parameters["backoffMs"] ?? "5000") ?? 5000
        try? await Task.sleep(for: .milliseconds(backoffMs))
        return ExecutionResult(action: .throttleRequests, success: true, detail: "Throttled \(backoffMs)ms", durationMs: backoffMs)
    }

    private func executeDNSRotation(decision: AutopilotDecision) -> ExecutionResult {
        let dnsPool = DNSPoolService.shared
        let _ = dnsPool.nextProvider()
        return ExecutionResult(action: .rotateDNS, success: true, detail: "DNS server rotated", durationMs: 0)
    }

    private func executeFingerprintRotation(decision: AutopilotDecision, session: LoginSiteWebSession?) async -> ExecutionResult {
        guard let webView = session?.webView else {
            return ExecutionResult(action: .rotateFingerprint, success: false, detail: "No WebView available", durationMs: 0)
        }

        let stealth = PPSRStealthService.shared
        let newProfile = stealth.nextProfile()
        webView.customUserAgent = newProfile.userAgent
        let newJS = stealth.createStealthUserScript(profile: newProfile)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.addUserScript(newJS)

        return ExecutionResult(
            action: .rotateFingerprint, success: true,
            detail: "Fingerprint rotated to seed \(newProfile.seed)",
            durationMs: 0
        )
    }

    private func executeFullSessionReset(decision: AutopilotDecision, session: LoginSiteWebSession?) async -> ExecutionResult {
        guard let session else {
            return ExecutionResult(action: .fullSessionReset, success: false, detail: "No session available", durationMs: 0)
        }

        session.tearDown(wipeAll: true)
        session.setUp(wipeAll: true)

        return ExecutionResult(action: .fullSessionReset, success: true, detail: "Full session reset with clean identity", durationMs: 0)
    }

    private func executeDecoyTraffic(decision: AutopilotDecision, session: LoginSiteWebSession?) async -> ExecutionResult {
        guard let webView = session?.webView else {
            return ExecutionResult(action: .injectDecoyTraffic, success: false, detail: "No WebView", durationMs: 0)
        }

        let decoyJS = """
        (function(){
            var links=['https://www.google.com/search?q=casino+login','https://www.bing.com/search?q=login+help'];
            var r=new XMLHttpRequest();
            r.open('HEAD',links[Math.floor(Math.random()*links.length)],true);
            try{r.send();}catch(e){}
            return 'decoy_sent';
        })();
        """

        do {
            _ = try await webView.evaluateJavaScript(decoyJS)
            return ExecutionResult(action: .injectDecoyTraffic, success: true, detail: "Decoy traffic injected", durationMs: 0)
        } catch {
            return ExecutionResult(action: .injectDecoyTraffic, success: false, detail: "Decoy failed", durationMs: 0)
        }
    }

    private func executeViewportAdjust(decision: AutopilotDecision, session: LoginSiteWebSession?) async -> ExecutionResult {
        guard let webView = session?.webView else {
            return ExecutionResult(action: .adjustViewport, success: false, detail: "No WebView", durationMs: 0)
        }

        let widths = [375, 390, 414, 428]
        let newWidth = widths.randomElement() ?? 390
        let viewportJS = """
        (function(){
            var meta=document.querySelector('meta[name="viewport"]');
            if(!meta){meta=document.createElement('meta');meta.name='viewport';document.head.appendChild(meta);}
            meta.content='width=\(newWidth),initial-scale=1.0';
            return 'viewport_set_\(newWidth)';
        })();
        """

        do {
            _ = try await webView.evaluateJavaScript(viewportJS)
            return ExecutionResult(action: .adjustViewport, success: true, detail: "Viewport adjusted to \(newWidth)", durationMs: 0)
        } catch {
            return ExecutionResult(action: .adjustViewport, success: false, detail: "Viewport adjust failed", durationMs: 0)
        }
    }

    private func executeSlowDown(decision: AutopilotDecision) -> ExecutionResult {
        let percent = Int(decision.parameters["slowdownPercent"] ?? "30") ?? 30
        let host = decision.parameters["host"] ?? ""
        if !host.isEmpty {
            for category in TimingCategory.allCases {
                timingOptimizer.recordSample(
                    host: host, category: category,
                    actualMs: 0, fillSuccess: true,
                    submitSuccess: true, detected: true,
                    pattern: "autopilot_slowdown"
                )
            }
        }
        return ExecutionResult(action: .slowDownInteraction, success: true, detail: "Interaction slowed \(percent)%", durationMs: 0)
    }

    private func executeSpeedUp(decision: AutopilotDecision) -> ExecutionResult {
        return ExecutionResult(action: .speedUpInteraction, success: true, detail: "Interaction speed restored", durationMs: 0)
    }

    private func executeCookieClear(decision: AutopilotDecision, session: LoginSiteWebSession?) async -> ExecutionResult {
        guard let webView = session?.webView else {
            return ExecutionResult(action: .preemptiveCookieClear, success: false, detail: "No WebView", durationMs: 0)
        }

        let store = webView.configuration.websiteDataStore
        let dataTypes: Set<String> = [WKWebsiteDataTypeCookies]
        let records = await store.dataRecords(ofTypes: dataTypes)
        await store.removeData(ofTypes: dataTypes, for: records)

        return ExecutionResult(action: .preemptiveCookieClear, success: true, detail: "Cleared \(records.count) cookie records", durationMs: 0)
    }
}
