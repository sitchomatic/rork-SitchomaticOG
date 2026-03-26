import Foundation

@MainActor
class LoginJSBuilder {
    static let shared = LoginJSBuilder()

    func escapeForJS(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
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

    let findFieldJS = """
    function findField(strategies) {
        for (var i = 0; i < strategies.length; i++) {
            var s = strategies[i];
            var el = null;
            try {
                if (s.type === 'id') {
                    el = document.getElementById(s.value);
                } else if (s.type === 'name') {
                    var els = document.getElementsByName(s.value);
                    if (els.length > 0) el = els[0];
                } else if (s.type === 'placeholder') {
                    el = document.querySelector('input[placeholder*="' + s.value + '"]');
                } else if (s.type === 'label') {
                    var labels = document.querySelectorAll('label');
                    for (var j = 0; j < labels.length; j++) {
                        var txt = (labels[j].textContent || '').trim().toLowerCase();
                        if (txt.indexOf(s.value.toLowerCase()) !== -1) {
                            var forId = labels[j].getAttribute('for');
                            if (forId) { el = document.getElementById(forId); }
                            else { el = labels[j].querySelector('input'); }
                            if (el) break;
                        }
                    }
                } else if (s.type === 'css') {
                    el = document.querySelector(s.value);
                } else if (s.type === 'ariaLabel') {
                    el = document.querySelector('[aria-label*="' + s.value + '"]');
                }
            } catch(e) {}
            if (el && !el.disabled && el.offsetParent !== null) return el;
            if (el && !el.disabled) return el;
        }
        return null;
    }
    """

    func fillFieldJS(strategies: String, value: String) -> String {
        let escaped = escapeForJS(value)
        return """
        (function() {
            \(findFieldJS)
            var el = findField(\(strategies));
            if (!el) return 'NOT_FOUND';
            el.focus();
            var nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (nativeInputValueSetter && nativeInputValueSetter.set) {
                nativeInputValueSetter.set.call(el, '');
            } else {
                el.value = '';
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (nativeInputValueSetter && nativeInputValueSetter.set) {
                nativeInputValueSetter.set.call(el, '\(escaped)');
            } else {
                el.value = '\(escaped)';
            }
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
    }

    func calibratedFillJS(selector: String, value: String) -> String {
        let safeSel = escapeForJS(selector)
        let safeVal = escapeForJS(value)
        return "(function(){ try { var el = document.querySelector('" + safeSel + "'); if (!el) return 'CAL_NOT_FOUND'; el.focus(); var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value'); if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; } el.dispatchEvent(new Event('input', {bubbles:true})); if (ns && ns.set) { ns.set.call(el, '" + safeVal + "'); } else { el.value = '" + safeVal + "'; } el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); return el.value.length > 0 ? 'CAL_OK' : 'CAL_MISMATCH'; } catch(e) { return 'CAL_ERROR'; } })()"
    }

    func calibratedClickJS(selector: String) -> String {
        let safeSel = escapeForJS(selector)
        return "(function(){ try { var el = document.querySelector('" + safeSel + "'); if (!el) return 'CAL_NOT_FOUND'; el.scrollIntoView({behavior:'instant',block:'center'}); var r = el.getBoundingClientRect(); var cx = r.left+r.width*0.5; var cy = r.top+r.height*0.5; el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1})); el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1})); el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0})); el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0})); el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0})); el.click(); return 'CAL_CLICKED:' + (el.textContent||'').trim().substring(0,20); } catch(e) { return 'CAL_ERROR'; } })()"
    }

    func coordinateFillJS(x: Int, y: Int, value: String, fieldName: String) -> String {
        let safeVal = escapeForJS(value)
        return "(function(){var el=document.elementFromPoint(\(x),\(y));if(!el)return'NO_EL';if(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA'){var inp=el.querySelector('input');if(inp)el=inp;}el.focus();var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}el.dispatchEvent(new Event('input',{bubbles:true}));if(ns&&ns.set){ns.set.call(el,'" + safeVal + "');}else{el.value='" + safeVal + "';}el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return el.value.length>0?'COORD_OK':'COORD_MISMATCH';})()"
    }

    func coordinateClickJS(x: Int, y: Int) -> String {
        "(function(){var cx=\(x);var cy=\(y);var el=document.elementFromPoint(cx,cy);if(!el)return'NO_EL';el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));try{el.click();}catch(e){}return'CAL_COORD:'+el.tagName;})()"
    }

    func trueDetectionFillJS(fieldId: String, value: String) -> String {
        let escaped = escapeForJS(value)
        return """
        (function() {
            var el = document.querySelector('#\(fieldId)');
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

    func tripleClickSubmitJS(attempt: Int) -> String {
        """
        (function() {
            var btn = document.querySelector('#login-submit');
            if (!btn) return 'NOT_FOUND';
            btn.scrollIntoView({behavior:'instant',block:'center'});
            var r = btn.getBoundingClientRect();
            var cx = r.left + r.width * (0.3 + Math.random() * 0.4);
            var cy = r.top + r.height * (0.3 + Math.random() * 0.4);
            btn.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
            btn.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0,buttons:1}));
            btn.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
            btn.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
            btn.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
            btn.click();
            return 'CLICKED_\(attempt)';
        })();
        """
    }

    func reactNativeSetterFillJS(username: String, password: String) -> String {
        let escapedUser = escapeForJS(username)
        let escapedPass = escapeForJS(password)
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

    func formSubmitDirectFillJS(username: String, password: String) -> String {
        let escapedUser = escapeForJS(username)
        let escapedPass = escapeForJS(password)
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

    let formSubmitJS = """
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
