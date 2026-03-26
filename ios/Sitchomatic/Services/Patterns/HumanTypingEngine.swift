import Foundation

@MainActor
class HumanTypingEngine {
    static let shared = HumanTypingEngine()

    private let logger = DebugLogger.shared

    func gaussianRandom(mean: Double, stdDev: Double) -> Double {
        let u1 = Double.random(in: 0.0001...0.9999)
        let u2 = Double.random(in: 0.0001...0.9999)
        let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return mean + z * stdDev
    }

    func humanDelay(minMs: Int, maxMs: Int) -> Int {
        let mean = Double(minMs + maxMs) / 2.0
        let stdDev = Double(maxMs - minMs) / 4.0
        let delay = gaussianRandom(mean: mean, stdDev: stdDev)
        return max(minMs, min(maxMs, Int(delay)))
    }

    func typeCharByChar(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String, minDelayMs: Int, maxDelayMs: Int) async -> Bool {
        let fieldType = fieldName == "password" ? "password" : "email"
        let fieldTypeFallback = fieldName == "password" ? "password" : "text"
        let clearJS = "(function(){var el=document.activeElement;if(!el||(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA')){var inp=document.querySelector('input[type=\"" + "\(fieldType)" + "\"]')||document.querySelector('input[type=\"" + "\(fieldTypeFallback)" + "\"]');if(inp){inp.focus();el=inp;}}if(!el)return'NO_EL';var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}el.dispatchEvent(new Event('input',{bubbles:true}));return'CLEARED';})()"
        _ = await executeJS(clearJS)

        for (index, char) in text.enumerated() {
            let charStr = String(char)
            let escaped = charStr.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
            let keyCode = charKeyCode(char)

            let typeOneCharJS = """
            (function(){
                var el = document.activeElement;
                if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) {
                    var inp = document.querySelector('input[type="\(fieldName == "password" ? "password" : "email")"]') || document.querySelector('input[type="\(fieldName == "password" ? "password" : "text")"]');
                    if (inp) { inp.focus(); el = inp; }
                }
                if (!el) return 'NO_ELEMENT';
                el.dispatchEvent(new KeyboardEvent('keydown',{key:'\(escaped)',code:'\(charCode(char))',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true}));
                el.dispatchEvent(new KeyboardEvent('keypress',{key:'\(escaped)',code:'\(charCode(char))',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true,charCode:\(keyCode)}));
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                var currentVal = el.value || '';
                var newVal = currentVal + '\(escaped)';
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                else { el.value = newVal; }
                el.dispatchEvent(new InputEvent('input',{bubbles:true,cancelable:false,inputType:'insertText',data:'\(escaped)'}));
                el.dispatchEvent(new KeyboardEvent('keyup',{key:'\(escaped)',code:'\(charCode(char))',keyCode:\(keyCode),which:\(keyCode),bubbles:true}));
                return 'TYPED';
            })()
            """
            let r = await executeJS(typeOneCharJS)
            if r != "TYPED" {
                logger.log("CharByChar: failed at index \(index) of \(fieldName): \(r ?? "nil")", category: .automation, level: .warning, sessionId: sessionId)
                return false
            }

            let delay = humanDelay(minMs: minDelayMs, maxMs: maxDelayMs)
            if index > 0 && index % Int.random(in: 4...8) == 0 {
                let thinkPause = humanDelay(minMs: 200, maxMs: 600)
                try? await Task.sleep(for: .milliseconds(delay + thinkPause))
            } else {
                try? await Task.sleep(for: .milliseconds(delay))
            }
        }

        let verifyJS = """
        (function(){
            var el = document.activeElement;
            if (!el) return 'NO_EL';
            return el.value ? el.value.length.toString() : '0';
        })()
        """
        let lenStr = await executeJS(verifyJS)
        let typedLen = Int(lenStr ?? "0") ?? 0
        let success = typedLen >= text.count
        if !success {
            logger.log("CharByChar: \(fieldName) verify failed — typed \(typedLen)/\(text.count) chars", category: .automation, level: .warning, sessionId: sessionId)
        }
        return success
    }

    func typeWithExecCommand(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String, minDelayMs: Int, maxDelayMs: Int) async -> Bool {
        let clearExecJS = "(function(){var el=document.activeElement;if(!el)return'NO_EL';el.select();document.execCommand('delete',false,null);if(el.value&&el.value.length>0){var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}el.dispatchEvent(new Event('input',{bubbles:true}));}return'CLEARED';})()"
        _ = await executeJS(clearExecJS)

        for (index, char) in text.enumerated() {
            let charStr = String(char)
            let escaped = charStr.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")

            let insertJS = """
            (function(){
                var el = document.activeElement;
                if (!el) return 'NO_EL';
                var success = document.execCommand('insertText', false, '\(escaped)');
                if (success) return 'EXEC_OK';
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                var newVal = (el.value || '') + '\(escaped)';
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                else { el.value = newVal; }
                el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(escaped)'}));
                return 'NATIVE_SET';
            })()
            """
            let r = await executeJS(insertJS)
            if r == "NO_EL" {
                logger.log("ExecCmd: no active element at index \(index) of \(fieldName)", category: .automation, level: .warning, sessionId: sessionId)
                return false
            }

            let delay = humanDelay(minMs: minDelayMs, maxMs: maxDelayMs)
            try? await Task.sleep(for: .milliseconds(delay))
        }

        return true
    }

    func typeSlowWithCorrections(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String) async -> Bool {
        let clearSlowJS = "(function(){var el=document.activeElement;if(!el)return'NO_EL';var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}el.dispatchEvent(new Event('input',{bubbles:true}));return'CLEARED';})()"
        _ = await executeJS(clearSlowJS)

        let correctionChance = 0.08
        var i = 0
        let chars = Array(text)

        while i < chars.count {
            if Double.random(in: 0...1) < correctionChance && i > 2 {
                let typoChar = "abcdefghijklmnopqrstuvwxyz".randomElement()!
                let typoEscaped = String(typoChar)

                let typeTypoJS = """
                (function(){
                    var el = document.activeElement;
                    if (!el) return 'NO_EL';
                    var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                    var newVal = (el.value || '') + '\(typoEscaped)';
                    if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                    else { el.value = newVal; }
                    el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(typoEscaped)'}));
                    return 'TYPO';
                })()
                """
                _ = await executeJS(typeTypoJS)
                logger.log("SlowTyper: deliberate typo '\(typoChar)' at pos \(i) in \(fieldName)", category: .automation, level: .trace, sessionId: sessionId)

                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 800)))

                let backspaceJS = """
                (function(){
                    var el = document.activeElement;
                    if (!el) return 'NO_EL';
                    el.dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',code:'Backspace',keyCode:8,which:8,bubbles:true,cancelable:true}));
                    var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                    var newVal = (el.value || '').slice(0, -1);
                    if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                    else { el.value = newVal; }
                    el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteContentBackward'}));
                    el.dispatchEvent(new KeyboardEvent('keyup',{key:'Backspace',code:'Backspace',keyCode:8,which:8,bubbles:true}));
                    return 'BS';
                })()
                """
                _ = await executeJS(backspaceJS)

                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))
            }

            let char = chars[i]
            let charStr = String(char)
            let escaped = charStr.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let kc = charKeyCode(char)

            let typeJS = """
            (function(){
                var el = document.activeElement;
                if (!el) return 'NO_EL';
                el.dispatchEvent(new KeyboardEvent('keydown',{key:'\(escaped)',keyCode:\(kc),which:\(kc),bubbles:true,cancelable:true}));
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                var newVal = (el.value || '') + '\(escaped)';
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                else { el.value = newVal; }
                el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(escaped)'}));
                el.dispatchEvent(new KeyboardEvent('keyup',{key:'\(escaped)',keyCode:\(kc),which:\(kc),bubbles:true}));
                return 'OK';
            })()
            """
            let r = await executeJS(typeJS)
            if r == "NO_EL" { return false }

            let delay = humanDelay(minMs: 120, maxMs: 350)
            if i > 0 && i % Int.random(in: 3...6) == 0 {
                try? await Task.sleep(for: .milliseconds(delay + humanDelay(minMs: 300, maxMs: 900)))
            } else {
                try? await Task.sleep(for: .milliseconds(delay))
            }

            i += 1
        }

        return true
    }

    func humanClickLoginButton(executeJS: @escaping (String) async -> String?, sessionId: String) async -> Bool {
        let ocrAndClickJS = """
        (function(){
            function findLoginBtn() {
                var loginTerms = ['log in','login','sign in','signin'];
                var allClickable = document.querySelectorAll('button, input[type="submit"], a, [role="button"], span, div');
                for (var i = 0; i < allClickable.length; i++) {
                    var el = allClickable[i];
                    var text = (el.textContent || el.value || '').replace(/[\\s]+/g,' ').toLowerCase().trim();
                    if (text.length > 50) continue;
                    for (var t = 0; t < loginTerms.length; t++) {
                        if (text === loginTerms[t] || (text.indexOf(loginTerms[t]) !== -1 && text.length < 25)) return el;
                    }
                }
                var submitBtn = document.querySelector('button[type="submit"]') || document.querySelector('input[type="submit"]');
                if (submitBtn) return submitBtn;
                var forms = document.querySelectorAll('form');
                for (var f = 0; f < forms.length; f++) {
                    if (forms[f].querySelector('input[type="password"]')) {
                        var btn = forms[f].querySelector('button') || forms[f].querySelector('[role="button"]');
                        if (btn) return btn;
                    }
                }
                return null;
            }
            var btn = findLoginBtn();
            if (!btn) return 'NOT_FOUND';
            btn.scrollIntoView({behavior:'smooth',block:'center'});
            var rect = btn.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) return 'ZERO_SIZE';
            var startX = rect.left - 30 - Math.random() * 50;
            var startY = rect.top + Math.random() * 30 - 15;
            var endX = rect.left + rect.width * (0.3 + Math.random() * 0.4);
            var endY = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            var steps = 4 + Math.floor(Math.random() * 4);
            for (var s = 0; s <= steps; s++) {
                var t = s / steps;
                var bezT = t * t * (3 - 2 * t);
                var mx = startX + (endX - startX) * bezT + (Math.random() * 1.5 - 0.75);
                var my = startY + (endY - startY) * bezT + (Math.random() * 1.5 - 0.75);
                try { btn.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:mx,clientY:my})); } catch(e){}
            }
            btn.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:endX,clientY:endY,pointerId:1,pointerType:'mouse'}));
            btn.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:endX,clientY:endY}));
            btn.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
            btn.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0,buttons:1}));
            btn.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,pointerId:1,pointerType:'mouse',button:0}));
            btn.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            btn.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            try { btn.click(); } catch(e){}
            var tag = btn.tagName || '';
            var txt = (btn.textContent || '').substring(0,20).trim();
            return 'CLICKED:' + tag + ':' + txt;
        })()
        """
        let r = await executeJS(ocrAndClickJS)
        logger.log("HumanClick login button: \(r ?? "nil")", category: .automation, level: r?.hasPrefix("CLICKED") == true ? .debug : .warning, sessionId: sessionId)

        if let r, r.hasPrefix("CLICKED") { return true }

        let enterFallbackJS = """
        (function(){
            var pass = document.querySelector('input[type="password"]');
            if (pass) {
                pass.focus();
                pass.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                pass.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                pass.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER';
            }
            var forms = document.querySelectorAll('form');
            for (var i = 0; i < forms.length; i++) {
                if (forms[i].querySelector('input[type="password"]')) {
                    try { forms[i].requestSubmit(); return 'REQUEST_SUBMIT'; } catch(e){}
                    try { forms[i].submit(); return 'FORM_SUBMIT'; } catch(e){}
                }
            }
            return 'FAILED';
        })()
        """
        let fallback = await executeJS(enterFallbackJS)
        logger.log("HumanClick fallback: \(fallback ?? "nil")", category: .automation, level: .debug, sessionId: sessionId)
        return fallback != "FAILED" && fallback != nil
    }

    func buildFindEmailFieldJS() -> String {
        """
        var el = document.querySelector('input[type="email"]')
            || document.querySelector('input[autocomplete="email"]')
            || document.querySelector('input[autocomplete="username"]')
            || document.querySelector('input[name="email"]')
            || document.querySelector('input[name="username"]')
            || document.querySelector('input[id="email"]')
            || document.querySelector('input[id="username"]')
            || document.querySelector('input[id="login-email"]')
            || document.querySelector('input[id="loginEmail"]')
            || document.querySelector('input[placeholder*="Email" i]')
            || document.querySelector('input[placeholder*="email" i]')
            || document.querySelector('input[placeholder*="Username" i]')
            || (function(){ var inputs = document.querySelectorAll('form input[type="text"]'); return inputs.length > 0 ? inputs[0] : null; })()
            || document.querySelector('input[type="text"]');
        """
    }

    func charKeyCode(_ char: Character) -> Int {
        let s = String(char).uppercased()
        guard let ascii = s.unicodeScalars.first?.value else { return 0 }
        if ascii >= 65 && ascii <= 90 { return Int(ascii) }
        if ascii >= 48 && ascii <= 57 { return Int(ascii) }
        switch char {
        case "@": return 50
        case ".": return 190
        case "-": return 189
        case "_": return 189
        case "!": return 49
        case "#": return 51
        case "$": return 52
        case "%": return 53
        case "&": return 55
        case "*": return 56
        case "+": return 187
        case "=": return 187
        default: return Int(ascii)
        }
    }

    func charCode(_ char: Character) -> String {
        let upper = String(char).uppercased()
        if char.isLetter { return "Key\(upper)" }
        if char.isNumber { return "Digit\(char)" }
        switch char {
        case "@": return "Digit2"
        case ".": return "Period"
        case "-": return "Minus"
        case "_": return "Minus"
        case " ": return "Space"
        case "!": return "Digit1"
        case "#": return "Digit3"
        case "$": return "Digit4"
        default: return "Key\(upper)"
        }
    }
}
