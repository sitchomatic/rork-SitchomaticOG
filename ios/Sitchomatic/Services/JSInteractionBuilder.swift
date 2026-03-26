import Foundation

@MainActor
struct JSInteractionBuilder {

    static func escapeJS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
    }

    static let findEmailFieldJS: String = """
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

    static func humanTapJS(selector: String) -> String {
        """
        (function() {
            var el = document.querySelector('\(selector)');
            if (!el) return 'NOT_FOUND';
            el.scrollIntoView({behavior: 'instant', block: 'center'});
            var rect = el.getBoundingClientRect();
            var cx = rect.left + rect.width / 2 + (Math.random() * 8 - 4);
            var cy = rect.top + rect.height / 2 + (Math.random() * 8 - 4);
            el.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch',button:0,buttons:1}));
            el.dispatchEvent(new TouchEvent('touchstart', {bubbles:true,cancelable:true,view:window}));
            el.dispatchEvent(new PointerEvent('pointerup', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch',button:0}));
            el.dispatchEvent(new TouchEvent('touchend', {bubbles:true,cancelable:true,view:window}));
            el.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
            return 'TAPPED';
        })();
        """
    }

    static func nativeSetterFillJS(selector: String, value: String) -> String {
        let escaped = escapeJS(value)
        return """
        (function() {
            var el = document.querySelector('\(selector)');
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
    }

    static func cycledSubmitClickJS(selector: String, clickIndex: Int) -> String {
        """
        (function() {
            var btn = document.querySelector('\(selector)');
            if (!btn) return 'NOT_FOUND';
            btn.scrollIntoView({behavior: 'instant', block: 'center'});
            var r = btn.getBoundingClientRect();
            var cx = r.left + r.width * (0.3 + Math.random() * 0.4);
            var cy = r.top + r.height * (0.3 + Math.random() * 0.4);
            btn.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
            btn.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0,buttons:1}));
            btn.dispatchEvent(new PointerEvent('pointerup', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
            btn.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
            btn.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
            btn.click();
            return 'CLICKED_' + \(clickIndex);
        })();
        """
    }

    static func focusEmailFieldJS() -> String {
        "(function(){ \(findEmailFieldJS) if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; el.dispatchEvent(new Event('focus',{bubbles:true})); return 'OK'; })()"
    }

    static func focusAndClickEmailFieldJS() -> String {
        """
        (function(){ \(findEmailFieldJS)
        if (el) {
            el.scrollIntoView({behavior:'smooth',block:'center'});
            el.click();
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles:true}));
            'FOCUSED';
        } else { 'NOT_FOUND'; }
        })()
        """
    }

    static func tabToPasswordJS() -> String {
        """
        (function(){
            var active = document.activeElement;
            if (active) {
                active.dispatchEvent(new KeyboardEvent('keydown', {key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true,cancelable:true}));
                active.dispatchEvent(new KeyboardEvent('keyup', {key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true}));
            }
            var passField = document.querySelector('input[type="password"]');
            if (passField) {
                passField.focus();
                passField.click();
                passField.dispatchEvent(new Event('focus', {bubbles:true}));
                return 'TAB_TO_PASS';
            }
            return 'TAB_SENT';
        })()
        """
    }

    static func enterKeySubmitJS() -> String {
        """
        (function(){
            var active = document.activeElement;
            if (!active) active = document.querySelector('input[type="password"]');
            if (active) {
                active.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                active.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                active.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER_PRESSED';
            }
            return 'NO_ACTIVE';
        })()
        """
    }

    static func enterKeyOnPasswordJS() -> String {
        """
        (function(){
            var pass = document.querySelector('input[type="password"]');
            if (pass) {
                pass.focus();
                pass.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                pass.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                pass.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER';
            }
            return 'NO_FIELD';
        })()
        """
    }

    static func blurAndFocusPasswordJS() -> String {
        """
        (function(){
            var active = document.activeElement;
            if (active) {
                active.dispatchEvent(new Event('blur',{bubbles:true}));
                active.dispatchEvent(new Event('change',{bubbles:true}));
            }
            var pass = document.querySelector('input[type="password"]');
            if (!pass) return 'NOT_FOUND';
            pass.focus();
            pass.click();
            pass.value = '';
            pass.dispatchEvent(new Event('focus',{bubbles:true}));
            return 'FOCUSED';
        })()
        """
    }

    static func mouseMoveThenClickEmailJS() -> String {
        """
        (function(){
            \(findEmailFieldJS)
            if (!el) return 'NOT_FOUND';
            el.scrollIntoView({behavior:'smooth',block:'center'});
            var rect = el.getBoundingClientRect();
            var startX = rect.left - 40 - Math.random() * 60;
            var startY = rect.top + Math.random() * 20 - 10;
            var endX = rect.left + rect.width * (0.2 + Math.random() * 0.6);
            var endY = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            var steps = 5 + Math.floor(Math.random() * 5);
            for (var i = 0; i <= steps; i++) {
                var t = i / steps;
                var bezT = t * t * (3 - 2 * t);
                var mx = startX + (endX - startX) * bezT + (Math.random() * 2 - 1);
                var my = startY + (endY - startY) * bezT + (Math.random() * 2 - 1);
                try { document.elementFromPoint(mx, my); } catch(e){}
                try { el.dispatchEvent(new MouseEvent('mousemove', {bubbles:true,clientX:mx,clientY:my})); } catch(e){}
            }
            el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            el.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles:true}));
            el.value = '';
            return 'CLICKED_EMAIL';
        })()
        """
    }

    static func blurAndMouseClickPasswordJS() -> String {
        """
        (function(){
            var emailField = document.activeElement;
            if (emailField) {
                emailField.dispatchEvent(new Event('blur', {bubbles:true}));
                emailField.dispatchEvent(new Event('change', {bubbles:true}));
            }
            var passField = document.querySelector('input[type="password"]');
            if (!passField) return 'NO_PASS_FIELD';
            passField.scrollIntoView({behavior:'smooth',block:'center'});
            var rect = passField.getBoundingClientRect();
            var cx = rect.left + rect.width * (0.2 + Math.random() * 0.6);
            var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            passField.dispatchEvent(new MouseEvent('mouseover', {bubbles:true,clientX:cx,clientY:cy}));
            passField.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            passField.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            passField.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            passField.focus();
            passField.dispatchEvent(new Event('focus', {bubbles:true}));
            passField.value = '';
            return 'CLICKED_PASS';
        })()
        """
    }

    static func touchFocusFieldJS(fieldSelector: String? = nil) -> String {
        let selectorBlock: String
        if let sel = fieldSelector {
            selectorBlock = "var el = document.querySelector('\(sel)');"
        } else {
            selectorBlock = findEmailFieldJS
        }
        return """
        (function(){
            \(selectorBlock)
            if (!el) return 'NOT_FOUND';
            el.scrollIntoView({behavior:'instant',block:'center'});
            var rect = el.getBoundingClientRect();
            var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
            var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            try {
                var t = new Touch({identifier:Date.now(),target:el,clientX:cx,clientY:cy,pageX:cx+window.scrollX,pageY:cy+window.scrollY});
                el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));
                el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));
            } catch(e) {
                el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
            }
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
            el.focus();
            el.value = '';
            el.dispatchEvent(new Event('focus',{bubbles:true}));
            return 'TOUCHED';
        })()
        """
    }

    static func focusSelectClearJS() -> String {
        "(function(){ \(findEmailFieldJS) if(!el) return 'NOT_FOUND'; el.focus(); el.select(); el.value=''; el.dispatchEvent(new Event('focus',{bubbles:true})); return 'FOCUSED'; })()"
    }

    static func blurAndFocusSelectPasswordJS() -> String {
        """
        (function(){
            var el = document.activeElement;
            if (el) { el.dispatchEvent(new Event('blur',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); }
            var pass = document.querySelector('input[type="password"]');
            if (!pass) return 'NOT_FOUND';
            pass.focus();
            pass.select();
            pass.value = '';
            pass.dispatchEvent(new Event('focus',{bubbles:true}));
            return 'FOCUSED';
        })()
        """
    }

    static func blurAndEnterSubmitJS() -> String {
        """
        (function(){
            var active = document.activeElement;
            if (active) { active.dispatchEvent(new Event('blur',{bubbles:true})); }
            var passField = document.querySelector('input[type="password"]');
            if (passField) {
                passField.focus();
                passField.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                passField.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                passField.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER_PRESSED';
            }
            return 'NO_FIELD';
        })()
        """
    }

    static func focusScrollClickEmailJS() -> String {
        "(function(){ \(findEmailFieldJS) if(!el) return 'NOT_FOUND'; el.scrollIntoView({behavior:'smooth',block:'center'}); el.focus(); el.click(); el.value=''; el.dispatchEvent(new Event('focus',{bubbles:true})); return 'OK'; })()"
    }

    static func fillBothFieldsJS(username: String, password: String) -> String {
        let escapedUser = escapeJS(username)
        let escapedPass = escapeJS(password)
        return """
        (function(){
            var emailField = document.querySelector('input[type="email"]')
                || document.querySelector('input[autocomplete="email"]')
                || document.querySelector('input[autocomplete="username"]')
                || document.querySelector('input[name="email"]')
                || document.querySelector('input[name="username"]')
                || document.querySelector('input[type="text"]');
            var passField = document.querySelector('input[type="password"]');
            if (!emailField || !passField) return JSON.stringify({email:false, pass:false});

            function setValue(el, val) {
                el.focus();
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, ''); } else { el.value = ''; }
                el.dispatchEvent(new Event('input', {bubbles:true}));
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, val); }
                else { el.value = val; }
                el.dispatchEvent(new Event('input', {bubbles:true}));
                el.dispatchEvent(new Event('change', {bubbles:true}));
                el.dispatchEvent(new Event('blur', {bubbles:true}));
            }

            setValue(emailField, '\(escapedUser)');
            setValue(passField, '\(escapedPass)');
            return JSON.stringify({email: emailField.value.length > 0, pass: passField.value.length > 0});
        })()
        """
    }

    static func formSubmitJS() -> String {
        """
        (function(){
            var forms = document.querySelectorAll('form');
            for (var i = 0; i < forms.length; i++) {
                if (forms[i].querySelector('input[type="password"]')) {
                    try { forms[i].requestSubmit(); return 'REQUEST_SUBMIT'; } catch(e){}
                    try { forms[i].submit(); return 'FORM_SUBMIT'; } catch(e){}
                }
            }
            if (forms.length > 0) {
                try { forms[0].requestSubmit(); return 'REQUEST_SUBMIT_FIRST'; } catch(e){}
                try { forms[0].submit(); return 'FORM_SUBMIT_FIRST'; } catch(e){}
            }
            return 'FAILED';
        })()
        """
    }

    static func reactNativeFillJS(username: String, password: String) -> String {
        let escapedUser = escapeJS(username)
        let escapedPass = escapeJS(password)
        return """
        (function(){
            function reactSet(el, val) {
                if (!el) return false;
                el.focus();
                var tracker = el._valueTracker;
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, ''); } else { el.value = ''; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                if (tracker) { tracker.setValue(''); }
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, val); }
                else { el.value = val; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                var inputEvent = new InputEvent('input', {bubbles: true, cancelable: false, inputType: 'insertText', data: val});
                el.dispatchEvent(inputEvent);
                return el.value === val || el.value.length > 0;
            }

            var emailField = document.querySelector('input[type="email"]')
                || document.querySelector('input[autocomplete="email"]')
                || document.querySelector('input[name="email"]')
                || document.querySelector('input[name="username"]')
                || document.querySelector('input[type="text"]');
            var passField = document.querySelector('input[type="password"]');

            var emailOK = reactSet(emailField, '\(escapedUser)');
            var passOK = reactSet(passField, '\(escapedPass)');
            return JSON.stringify({email: emailOK, pass: passOK});
        })()
        """
    }

    static func coordinateClickJS(x: Int, y: Int) -> String {
        """
        (function(){
            var el = document.elementFromPoint(\(x), \(y));
            if (!el) return 'NO_ELEMENT';
            if (el.tagName !== 'INPUT') { var inp = el.querySelector('input'); if (inp) el = inp; }
            el.focus(); el.click(); el.value = '';
            el.dispatchEvent(new Event('focus', {bubbles:true}));
            return 'FOCUSED';
        })()
        """
    }

    static func coordinateButtonClickJS(x: Int, y: Int) -> String {
        """
        (function(){
            var cx = \(x); var cy = \(y);
            var el = document.elementFromPoint(cx, cy);
            if (!el) return 'NO_ELEMENT';
            el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
            el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));
            el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
            el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            try { el.click(); } catch(e){}
            return 'COORD_CLICKED:' + el.tagName;
        })()
        """
    }

    static func visibleInputFallbackJS() -> String {
        """
        (function(){
            var inputs = document.querySelectorAll('input:not([type=hidden]):not([type=password])');
            for (var i = 0; i < inputs.length; i++) {
                var inp = inputs[i];
                if (inp.offsetParent !== null || inp.offsetWidth > 0) {
                    inp.focus(); inp.click(); inp.value = '';
                    inp.dispatchEvent(new Event('focus',{bubbles:true}));
                    return 'FOUND';
                }
            }
            return 'NOT_FOUND';
        })()
        """
    }

    static func focusPasswordJS() -> String {
        "(function(){ var el = document.querySelector('input[type=\"password\"]'); if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; el.dispatchEvent(new Event('focus',{bubbles:true})); return 'OK'; })()"
    }

    static func humanClickLoginButtonJS() -> String {
        """
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
    }

    static func enterFallbackSubmitJS() -> String {
        """
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
    }

    static func calibratedFillJS(calibration: LoginCalibrationService.URLCalibration?, fieldType: String, value: String) -> String {
        let escaped = escapeJS(value)
        var selectors: [String] = []

        if let cal = calibration {
            let mapping = fieldType == "email" ? cal.emailField : cal.passwordField
            if let m = mapping {
                if !m.cssSelector.isEmpty { selectors.append(m.cssSelector) }
                selectors.append(contentsOf: m.fallbackSelectors)
            }
        }

        if fieldType == "email" {
            selectors.append(contentsOf: ["input[type='email']", "input[autocomplete='email']", "input[name='email']", "input[name='username']", "input[type='text']"])
        } else {
            selectors.append(contentsOf: ["input[type='password']", "input[autocomplete='current-password']", "input[name='password']"])
        }

        let selectorJSON = selectors.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ",")

        return """
        (function(){
            var selectors = [\(selectorJSON)];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var el = document.querySelector(selectors[i]);
                    if (el && !el.disabled) {
                        el.focus();
                        var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                        if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, ''); } else { el.value = ''; }
                        el.dispatchEvent(new Event('input', {bubbles:true}));
                        if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, '\(escaped)'); }
                        else { el.value = '\(escaped)'; }
                        el.dispatchEvent(new Event('input', {bubbles:true}));
                        el.dispatchEvent(new Event('change', {bubbles:true}));
                        if (el.value === '\(escaped)') return 'CAL_OK';
                        return 'CAL_MISMATCH';
                    }
                } catch(e) {}
            }
            return 'NOT_FOUND';
        })()
        """
    }

    static func calibratedFocusJS(calibration: LoginCalibrationService.URLCalibration?, fieldType: String) -> String {
        var selectors: [String] = []

        if let cal = calibration {
            let mapping = fieldType == "email" ? cal.emailField : cal.passwordField
            if let m = mapping {
                if !m.cssSelector.isEmpty { selectors.append(m.cssSelector) }
                selectors.append(contentsOf: m.fallbackSelectors)
            }
        }

        if fieldType == "email" {
            selectors.append(contentsOf: ["input[type='email']", "input[name='email']", "input[name='username']", "input[type='text']"])
        } else {
            selectors.append(contentsOf: ["input[type='password']", "input[name='password']"])
        }

        let selectorJSON = selectors.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ",")

        return """
        (function(){
            var selectors = [\(selectorJSON)];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var el = document.querySelector(selectors[i]);
                    if (el && !el.disabled) {
                        el.scrollIntoView({behavior:'instant',block:'center'});
                        el.focus(); el.click(); el.value = '';
                        el.dispatchEvent(new Event('focus', {bubbles:true}));
                        return 'FOCUSED';
                    }
                } catch(e) {}
            }
            return 'NOT_FOUND';
        })()
        """
    }

    static func typeOneCharJS(char: Character, fieldType: String) -> String {
        let charStr = String(char)
        let escaped = escapeJS(charStr)
        let keyCode = charKeyCode(char)
        let code = charCode(char)
        let fieldTypeFallback = fieldType == "password" ? "password" : "text"
        return """
        (function(){
            var el = document.activeElement;
            if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) {
                var inp = document.querySelector('input[type="\(fieldType)"]') || document.querySelector('input[type="\(fieldTypeFallback)"]');
                if (inp) { inp.focus(); el = inp; }
            }
            if (!el) return 'NO_ELEMENT';
            el.dispatchEvent(new KeyboardEvent('keydown',{key:'\(escaped)',code:'\(code)',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keypress',{key:'\(escaped)',code:'\(code)',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true,charCode:\(keyCode)}));
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            var currentVal = el.value || '';
            var newVal = currentVal + '\(escaped)';
            if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
            else { el.value = newVal; }
            el.dispatchEvent(new InputEvent('input',{bubbles:true,cancelable:false,inputType:'insertText',data:'\(escaped)'}));
            el.dispatchEvent(new KeyboardEvent('keyup',{key:'\(escaped)',code:'\(code)',keyCode:\(keyCode),which:\(keyCode),bubbles:true}));
            return 'TYPED';
        })()
        """
    }

    static func clearFieldJS(fieldType: String) -> String {
        let fieldTypeFallback = fieldType == "password" ? "password" : "text"
        return "(function(){var el=document.activeElement;if(!el||(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA')){var inp=document.querySelector('input[type=\"\(fieldType)\"]')||document.querySelector('input[type=\"\(fieldTypeFallback)\"]');if(inp){inp.focus();el=inp;}}if(!el)return'NO_EL';var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}el.dispatchEvent(new Event('input',{bubbles:true}));return'CLEARED';})()"
    }

    static func verifyFieldLengthJS() -> String {
        """
        (function(){
            var el = document.activeElement;
            if (!el) return 'NO_EL';
            return el.value ? el.value.length.toString() : '0';
        })()
        """
    }

    static func execCommandInsertCharJS(char: Character) -> String {
        let escaped = escapeJS(String(char))
        return """
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
    }

    static func execCommandClearJS() -> String {
        "(function(){var el=document.activeElement;if(!el)return'NO_EL';el.select();document.execCommand('delete',false,null);if(el.value&&el.value.length>0){var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}el.dispatchEvent(new Event('input',{bubbles:true}));}return'CLEARED';})()"
    }

    static func slowTypeClearJS() -> String {
        "(function(){var el=document.activeElement;if(!el)return'NO_EL';var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}el.dispatchEvent(new Event('input',{bubbles:true}));return'CLEARED';})()"
    }

    static func slowTypeCharJS(char: Character) -> String {
        let escaped = escapeJS(String(char))
        let kc = charKeyCode(char)
        return """
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
    }

    static func slowTypeTypoJS(char: Character) -> String {
        let escaped = String(char)
        return """
        (function(){
            var el = document.activeElement;
            if (!el) return 'NO_EL';
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            var newVal = (el.value || '') + '\(escaped)';
            if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
            else { el.value = newVal; }
            el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(escaped)'}));
            return 'TYPO';
        })()
        """
    }

    static func backspaceJS() -> String {
        """
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
    }

    static func charKeyCode(_ char: Character) -> Int {
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

    static func charCode(_ char: Character) -> String {
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
