import Foundation
import WebKit
import UIKit

@MainActor
class AntiBotDetectionService {
    static let shared = AntiBotDetectionService()

    private let logger = DebugLogger.shared
    private let visionML = VisionMLService.shared

    nonisolated enum InteractionMethod: String, Sendable {
        case coordinateTap
        case visionMLTap
        case touchEventDispatch
        case pointerEventChain
        case nativeInputSetter
        case activeElementFill
        case syntheticKeySequence
    }

    func findAndClickElement(
        label: String,
        in webView: WKWebView,
        settings: AutomationSettings,
        sessionId: String
    ) async -> Bool {
        logger.log("AntiBot: finding element '\(label)' using non-selector methods", category: .automation, level: .info, sessionId: sessionId)

        let screenshot = await captureScreenshot(webView)

        if let screenshot {
            let viewportSize = webView.frame.size.width > 0 ? webView.frame.size : CGSize(width: 390, height: 844)
            let hit = await visionML.findTextOnScreen(label, in: screenshot, viewportSize: viewportSize)
            if let hit {
                logger.log("AntiBot: Vision ML found '\(label)' at (\(Int(hit.pixelCoordinate.x)),\(Int(hit.pixelCoordinate.y)))", category: .automation, level: .info, sessionId: sessionId)
                let clicked = await dispatchTouchChain(x: hit.pixelCoordinate.x, y: hit.pixelCoordinate.y, in: webView, settings: settings, sessionId: sessionId)
                if clicked { return true }
            }
        }

        if let screenshot {
            let viewportSize = webView.frame.size.width > 0 ? webView.frame.size : CGSize(width: 390, height: 844)
            let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)
            if let btnHit = detection.loginButton {
                logger.log("AntiBot: Vision ML detected login button '\(btnHit.label)' at (\(Int(btnHit.pixelCoordinate.x)),\(Int(btnHit.pixelCoordinate.y)))", category: .automation, level: .info, sessionId: sessionId)
                let clicked = await dispatchTouchChain(x: btnHit.pixelCoordinate.x, y: btnHit.pixelCoordinate.y, in: webView, settings: settings, sessionId: sessionId)
                if clicked { return true }
            }
        }

        let textSearchResult = await findElementByVisibleText(label, in: webView)
        if let coord = textSearchResult {
            logger.log("AntiBot: text search found '\(label)' at (\(Int(coord.x)),\(Int(coord.y)))", category: .automation, level: .info, sessionId: sessionId)
            return await dispatchTouchChain(x: coord.x, y: coord.y, in: webView, settings: settings, sessionId: sessionId)
        }

        logger.log("AntiBot: could not find element '\(label)' by any method", category: .automation, level: .warning, sessionId: sessionId)
        return false
    }

    func findAndFillField(
        fieldType: FieldType,
        value: String,
        in webView: WKWebView,
        settings: AutomationSettings,
        sessionId: String
    ) async -> Bool {
        logger.log("AntiBot: filling \(fieldType.rawValue) field using anti-detection methods", category: .automation, level: .info, sessionId: sessionId)

        let screenshot = await captureScreenshot(webView)
        if let screenshot {
            let viewportSize = webView.frame.size.width > 0 ? webView.frame.size : CGSize(width: 390, height: 844)
            let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)

            var targetCoord: CGPoint?
            switch fieldType {
            case .email:
                targetCoord = detection.emailField?.pixelCoordinate
            case .password:
                targetCoord = detection.passwordField?.pixelCoordinate
            }

            if let coord = targetCoord {
                logger.log("AntiBot: Vision ML found \(fieldType.rawValue) at (\(Int(coord.x)),\(Int(coord.y)))", category: .automation, level: .info, sessionId: sessionId)
                let tapped = await dispatchTouchChain(x: coord.x, y: coord.y, in: webView, settings: settings, sessionId: sessionId)
                if tapped {
                    try? await Task.sleep(for: .milliseconds(settings.fieldFocusDelayMs))
                    return await fillActiveElement(value: value, in: webView, settings: settings, sessionId: sessionId)
                }
            }
        }

        let fieldCoord = await probeFieldByPosition(fieldType: fieldType, in: webView)
        if let coord = fieldCoord {
            logger.log("AntiBot: positional probe found \(fieldType.rawValue) at (\(Int(coord.x)),\(Int(coord.y)))", category: .automation, level: .info, sessionId: sessionId)
            let tapped = await dispatchTouchChain(x: coord.x, y: coord.y, in: webView, settings: settings, sessionId: sessionId)
            if tapped {
                try? await Task.sleep(for: .milliseconds(settings.fieldFocusDelayMs))
                return await fillActiveElement(value: value, in: webView, settings: settings, sessionId: sessionId)
            }
        }

        let tabFilled = await fillByTabNavigation(fieldType: fieldType, value: value, in: webView, settings: settings, sessionId: sessionId)
        if tabFilled { return true }

        logger.log("AntiBot: all fill strategies exhausted for \(fieldType.rawValue)", category: .automation, level: .error, sessionId: sessionId)
        return false
    }

    func dispatchTouchChain(
        x: CGFloat,
        y: CGFloat,
        in webView: WKWebView,
        settings: AutomationSettings,
        sessionId: String
    ) async -> Bool {
        let jitterX = settings.loginButtonClickOffsetJitter ? Double.random(in: -Double(settings.loginButtonClickOffsetMaxPx)...Double(settings.loginButtonClickOffsetMaxPx)) : 0
        let jitterY = settings.loginButtonClickOffsetJitter ? Double.random(in: -Double(settings.loginButtonClickOffsetMaxPx)...Double(settings.loginButtonClickOffsetMaxPx)) : 0
        let finalX = x + jitterX
        let finalY = y + jitterY

        if settings.loginButtonHoverBeforeClick {
            let hoverJS = buildHoverJS(x: finalX, y: finalY)
            _ = await safeEvalJS(hoverJS, in: webView)
            try? await Task.sleep(for: .milliseconds(settings.loginButtonHoverDurationMs))
        }

        let touchChainJS = buildAntiDetectionTouchChain(x: finalX, y: finalY)
        let result = await safeEvalJS(touchChainJS, in: webView)

        let success = result?.contains("OK") == true || result?.contains("CLICKED") == true
        if success {
            logger.log("AntiBot: touch chain dispatched at (\(Int(finalX)),\(Int(finalY))) — \(result ?? "")", category: .automation, level: .debug, sessionId: sessionId)
        } else {
            logger.log("AntiBot: touch chain failed at (\(Int(finalX)),\(Int(finalY))) — \(result ?? "nil")", category: .automation, level: .warning, sessionId: sessionId)
        }
        return success
    }

    func fillActiveElement(
        value: String,
        in webView: WKWebView,
        settings: AutomationSettings,
        sessionId: String
    ) async -> Bool {
        if settings.clearFieldsBeforeTyping {
            let clearJS = buildFieldClearJS(method: settings.clearFieldMethod)
            _ = await safeEvalJS(clearJS, in: webView)
            try? await Task.sleep(for: .milliseconds(50))
        }

        if settings.typingJitterEnabled {
            return await typeWithHumanSimulation(value, in: webView, settings: settings, sessionId: sessionId)
        } else {
            return await directSetValue(value, in: webView, sessionId: sessionId)
        }
    }

    // MARK: - Private

    private func typeWithHumanSimulation(_ text: String, in webView: WKWebView, settings: AutomationSettings, sessionId: String) async -> Bool {
        for char in text {
            let charStr = String(char).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
            let kc = charKeyCode(char)

            if settings.occasionalBackspaceEnabled && Double.random(in: 0...1) < settings.backspaceProbability {
                let typoJS = buildKeyEventJS(key: String(Character(UnicodeScalar(Int.random(in: 97...122))!)), keyCode: Int.random(in: 65...90))
                _ = await safeEvalJS(typoJS, in: webView)
                let typoDelay = Int.random(in: settings.typingSpeedMinMs...settings.typingSpeedMaxMs)
                try? await Task.sleep(for: .milliseconds(typoDelay))
                let backspaceJS = buildKeyEventJS(key: "Backspace", keyCode: 8)
                _ = await safeEvalJS(backspaceJS, in: webView)
                let bsDelay = Int.random(in: 30...80)
                try? await Task.sleep(for: .milliseconds(bsDelay))
            }

            let typeJS = buildCharInputJS(char: charStr, keyCode: kc)
            _ = await safeEvalJS(typeJS, in: webView)

            let delay: Int
            if settings.gaussianTimingDistribution {
                let mean = Double(settings.typingSpeedMinMs + settings.typingSpeedMaxMs) / 2.0
                let stdDev = Double(settings.typingSpeedMaxMs - settings.typingSpeedMinMs) / 4.0
                let u1 = Double.random(in: 0.0001...0.9999)
                let u2 = Double.random(in: 0.0001...0.9999)
                let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
                delay = max(settings.typingSpeedMinMs, min(settings.typingSpeedMaxMs, Int(mean + z * stdDev)))
            } else {
                delay = Int.random(in: settings.typingSpeedMinMs...settings.typingSpeedMaxMs)
            }
            try? await Task.sleep(for: .milliseconds(delay))
        }

        let verifyJS = "(function(){ var el=document.activeElement; return el && el.value ? el.value.length.toString() : '0'; })()"
        let result = await safeEvalJS(verifyJS, in: webView)
        let resultLen = Int(result ?? "0") ?? 0
        let success = resultLen >= text.count
        if !success {
            logger.log("AntiBot: typed \(text.count) chars but field has \(resultLen)", category: .automation, level: .warning, sessionId: sessionId)
        }
        return success
    }

    private func directSetValue(_ value: String, in webView: WKWebView, sessionId: String) async -> Bool {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
            var el=document.activeElement;
            if(!el||el===document.body)return 'NO_ACTIVE';
            var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');
            if(ns&&ns.set){ns.set.call(el,'\(escaped)');}else{el.value='\(escaped)';}
            el.dispatchEvent(new Event('input',{bubbles:true}));
            el.dispatchEvent(new Event('change',{bubbles:true}));
            return el.value.length>0?'OK':'EMPTY';
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func probeFieldByPosition(fieldType: FieldType, in webView: WKWebView) async -> CGPoint? {
        let js = """
        (function(){
            var inputs=document.querySelectorAll('input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button])');
            var results=[];
            for(var i=0;i<inputs.length;i++){
                var r=inputs[i].getBoundingClientRect();
                if(r.width>30&&r.height>10&&r.top>0){
                    results.push({
                        x:Math.round(r.left+r.width/2),
                        y:Math.round(r.top+r.height/2),
                        type:inputs[i].type||'text',
                        auto:inputs[i].autocomplete||'',
                        name:inputs[i].name||'',
                        placeholder:inputs[i].placeholder||''
                    });
                }
            }
            return JSON.stringify(results);
        })()
        """
        guard let result = await safeEvalJS(js, in: webView),
              let data = result.data(using: .utf8) else { return nil }

        struct FieldInfo: Decodable {
            let x: Int
            let y: Int
            let type: String
            let auto: String
            let name: String
            let placeholder: String
        }

        guard let fields = try? JSONDecoder().decode([FieldInfo].self, from: data) else { return nil }

        switch fieldType {
        case .email:
            if let f = fields.first(where: { $0.type == "email" || $0.auto.contains("email") || $0.auto.contains("username") || $0.name.contains("email") || $0.name.contains("user") || $0.placeholder.lowercased().contains("email") || $0.placeholder.lowercased().contains("user") }) {
                return CGPoint(x: f.x, y: f.y)
            }
            if let f = fields.first(where: { $0.type == "text" }) {
                return CGPoint(x: f.x, y: f.y)
            }
        case .password:
            if let f = fields.first(where: { $0.type == "password" }) {
                return CGPoint(x: f.x, y: f.y)
            }
        }
        return nil
    }

    private func fillByTabNavigation(fieldType: FieldType, value: String, in webView: WKWebView, settings: AutomationSettings, sessionId: String) async -> Bool {
        let tabJS = """
        (function(){
            var el=document.activeElement;
            if(!el||el===document.body){
                var first=document.querySelector('input:not([type=hidden])');
                if(first)first.focus();
                el=document.activeElement;
            }
            if(!el||el===document.body)return 'NO_FOCUSABLE';
            return el.type||'unknown';
        })()
        """
        let currentType = await safeEvalJS(tabJS, in: webView)

        let targetType = fieldType == .password ? "password" : "email"
        if currentType != targetType {
            for _ in 0..<5 {
                let tabKeyJS = buildKeyEventJS(key: "Tab", keyCode: 9)
                _ = await safeEvalJS(tabKeyJS, in: webView)
                try? await Task.sleep(for: .milliseconds(100))
                let checkJS = "(function(){ var el=document.activeElement; return el?el.type||'unknown':'none'; })()"
                let nowType = await safeEvalJS(checkJS, in: webView)
                if nowType == targetType { break }
                if fieldType == .email && (nowType == "text" || nowType == "email") { break }
            }
        }

        return await fillActiveElement(value: value, in: webView, settings: settings, sessionId: sessionId)
    }

    private func findElementByVisibleText(_ text: String, in webView: WKWebView) async -> CGPoint? {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
            var lower='\(escaped)'.toLowerCase();
            var all=document.querySelectorAll('button,a,[role=button],input[type=submit],input[type=button],span,div,label');
            for(var i=0;i<all.length;i++){
                var el=all[i];
                var txt=(el.textContent||el.value||el.getAttribute('aria-label')||'').trim().toLowerCase();
                if(txt===lower||txt.indexOf(lower)!==-1){
                    var r=el.getBoundingClientRect();
                    if(r.width>10&&r.height>10&&r.top>0){
                        return JSON.stringify({x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)});
                    }
                }
            }
            return 'NOT_FOUND';
        })()
        """
        guard let result = await safeEvalJS(js, in: webView),
              result != "NOT_FOUND",
              let data = result.data(using: .utf8) else { return nil }

        struct CoordResult: Decodable {
            let x: Int
            let y: Int
        }
        guard let coord = try? JSONDecoder().decode(CoordResult.self, from: data) else { return nil }
        return CGPoint(x: coord.x, y: coord.y)
    }

    private func buildAntiDetectionTouchChain(x: Double, y: Double) -> String {
        let ix = Int(x)
        let iy = Int(y)
        let timestamp = "Date.now()"
        return """
        (function(){
            var el=document.elementFromPoint(\(ix),\(iy));
            if(!el)return 'NO_ELEMENT';
            try{
                var ts=\(timestamp);
                var pointerOpts={bubbles:true,cancelable:true,clientX:\(ix),clientY:\(iy),screenX:\(ix),screenY:\(iy),pointerId:1,pointerType:'touch',isPrimary:true,width:1,height:1,pressure:0.5,tiltX:0,tiltY:0,twist:0};
                el.dispatchEvent(new PointerEvent('pointerover',Object.assign({},pointerOpts)));
                el.dispatchEvent(new PointerEvent('pointerenter',Object.assign({},pointerOpts,{bubbles:false})));
                el.dispatchEvent(new PointerEvent('pointerdown',Object.assign({},pointerOpts,{button:0,buttons:1})));
                try{
                    var touch=new Touch({identifier:ts,target:el,clientX:\(ix),clientY:\(iy),screenX:\(ix),screenY:\(iy),pageX:\(ix)+window.scrollX,pageY:\(iy)+window.scrollY,radiusX:11.5,radiusY:11.5,rotationAngle:0,force:0.5});
                    el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[touch],targetTouches:[touch],changedTouches:[touch]}));
                    el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[touch]}));
                }catch(te){}
                el.dispatchEvent(new PointerEvent('pointerup',Object.assign({},pointerOpts,{button:0,buttons:0})));
                el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(ix),clientY:\(iy),button:0,buttons:1,detail:1}));
                el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(ix),clientY:\(iy),button:0,buttons:0,detail:1}));
                el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(ix),clientY:\(iy),button:0,detail:1}));
                el.focus();
                if(typeof el.click==='function'&&el.tagName!=='INPUT')el.click();
                if(el.tagName==='BUTTON'||el.type==='submit'){
                    var form=el.closest('form');
                    if(form){try{form.requestSubmit();}catch(e){form.submit();}}
                }
                if(el.tagName==='A'&&el.href)window.location.href=el.href;
                return 'CLICKED:'+el.tagName;
            }catch(e){return 'ERROR:'+e.message;}
        })()
        """
    }

    private func buildHoverJS(x: Double, y: Double) -> String {
        let ix = Int(x)
        let iy = Int(y)
        return """
        (function(){
            var el=document.elementFromPoint(\(ix),\(iy));
            if(!el)return 'NO_ELEMENT';
            el.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,cancelable:true,clientX:\(ix),clientY:\(iy),pointerId:1,pointerType:'mouse'}));
            el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,cancelable:true,clientX:\(ix),clientY:\(iy)}));
            el.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false,cancelable:false,clientX:\(ix),clientY:\(iy)}));
            el.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,cancelable:true,clientX:\(ix),clientY:\(iy)}));
            return 'OK';
        })()
        """
    }

    private func buildFieldClearJS(method: AutomationSettings.FieldClearMethod) -> String {
        switch method {
        case .selectAllDelete:
            return """
            (function(){
                var el=document.activeElement;
                if(!el)return 'NO_ACTIVE';
                el.select();
                document.execCommand('delete');
                return 'OK';
            })()
            """
        case .tripleClickDelete:
            return """
            (function(){
                var el=document.activeElement;
                if(!el)return 'NO_ACTIVE';
                el.setSelectionRange(0,el.value?el.value.length:0);
                document.execCommand('delete');
                return 'OK';
            })()
            """
        case .jsValueClear:
            return """
            (function(){
                var el=document.activeElement;
                if(!el)return 'NO_ACTIVE';
                var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');
                if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}
                el.dispatchEvent(new Event('input',{bubbles:true}));
                return 'OK';
            })()
            """
        case .backspaceLoop:
            return """
            (function(){
                var el=document.activeElement;
                if(!el||!el.value)return 'NO_VALUE';
                for(var i=el.value.length;i>0;i--){
                    el.dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',keyCode:8,which:8,bubbles:true}));
                    el.value=el.value.slice(0,-1);
                    el.dispatchEvent(new Event('input',{bubbles:true}));
                    el.dispatchEvent(new KeyboardEvent('keyup',{key:'Backspace',keyCode:8,which:8,bubbles:true}));
                }
                return 'OK';
            })()
            """
        }
    }

    private func buildCharInputJS(char: String, keyCode: Int) -> String {
        return """
        (function(){
            var el=document.activeElement;
            if(!el||el===document.body)return 'NO_ACTIVE';
            el.dispatchEvent(new KeyboardEvent('keydown',{key:'\(char)',keyCode:\(keyCode),which:\(keyCode),code:'Key'+'\(char)'.toUpperCase(),bubbles:true,cancelable:true,isTrusted:false}));
            var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');
            var nv=(el.value||'')+'\(char)';
            if(ns&&ns.set){ns.set.call(el,nv);}else{el.value=nv;}
            el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(char)',cancelable:false}));
            el.dispatchEvent(new KeyboardEvent('keyup',{key:'\(char)',keyCode:\(keyCode),which:\(keyCode),code:'Key'+'\(char)'.toUpperCase(),bubbles:true}));
            return 'OK';
        })()
        """
    }

    private func buildKeyEventJS(key: String, keyCode: Int) -> String {
        return """
        (function(){
            var el=document.activeElement||document.body;
            el.dispatchEvent(new KeyboardEvent('keydown',{key:'\(key)',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true}));
            if('\(key)'==='Backspace'&&el.value){
                var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');
                var nv=el.value.slice(0,-1);
                if(ns&&ns.set){ns.set.call(el,nv);}else{el.value=nv;}
                el.dispatchEvent(new Event('input',{bubbles:true}));
            }
            if('\(key)'==='Tab'){
                var focusable=Array.from(document.querySelectorAll('input:not([type=hidden]),textarea,select,button,[tabindex]')).filter(function(e){return e.offsetParent!==null;});
                var idx=focusable.indexOf(el);
                if(idx>=0&&idx<focusable.length-1){focusable[idx+1].focus();}
                else if(focusable.length>0){focusable[0].focus();}
            }
            if('\(key)'==='Enter'){
                el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',keyCode:13,which:13,bubbles:true}));
                if(el.form){try{el.form.requestSubmit();}catch(e){el.form.submit();}}
            }
            el.dispatchEvent(new KeyboardEvent('keyup',{key:'\(key)',keyCode:\(keyCode),which:\(keyCode),bubbles:true}));
            return 'OK';
        })()
        """
    }

    private func captureScreenshot(_ webView: WKWebView) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Int(webView.frame.width))
        do {
            return try await webView.takeSnapshot(configuration: config)
        } catch {
            return nil
        }
    }

    func safeEvalJS(_ js: String, in webView: WKWebView) async -> String? {
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            return nil
        }
    }

    private func charKeyCode(_ char: Character) -> Int {
        let s = String(char).uppercased()
        guard let ascii = s.unicodeScalars.first?.value else { return 0 }
        if ascii >= 65 && ascii <= 90 { return Int(ascii) }
        if ascii >= 48 && ascii <= 57 { return Int(ascii) }
        switch char {
        case "@": return 50
        case ".": return 190
        case "-": return 189
        case "_": return 189
        default: return Int(ascii)
        }
    }

    nonisolated enum FieldType: String, Sendable {
        case email
        case password
    }
}
