import Foundation

struct DebugClickJSFactory {

    struct ClickMethod {
        let name: String
        let js: String
    }

    // MARK: - Click Type JS Generators

    private static func nativeClickCode(prefix: String) -> String {
        "el.click(); return '\(prefix):'+el.tagName+':'+text;"
    }

    private static func humanTouchClickCode(prefix: String) -> String {
        """
        var r=el.getBoundingClientRect();var cx=r.left+r.width*(0.3+Math.random()*0.4);var cy=r.top+r.height*(0.3+Math.random()*0.4);
        el.focus();
        el.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'}));
        el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:cx,clientY:cy}));
        el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
        el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));
        el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
        el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
        el.click();
        return '\(prefix):'+el.tagName+':'+text;
        """
    }

    private static func pointerClickCode(prefix: String) -> String {
        """
        var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
        el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch',button:0,buttons:1}));
        el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch',button:0}));
        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
        return '\(prefix):'+el.tagName+':'+text;
        """
    }

    private static func touchClickCode(prefix: String) -> String {
        """
        var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
        try{var t=new Touch({identifier:Date.now(),target:el,clientX:cx,clientY:cy,pageX:cx+window.scrollX,pageY:cy+window.scrollY});
        el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));
        el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));}catch(e){}
        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
        el.click();
        return '\(prefix):'+el.tagName+':'+text;
        """
    }

    private static func dispatchClickCode(prefix: String) -> String {
        "el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window})); return '\(prefix):'+el.tagName+':'+text;"
    }

    private static func mousedownUpClickCode(prefix: String) -> String {
        """
        var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
        el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));
        el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
        return '\(prefix):'+el.tagName+':'+text;
        """
    }

    private static func focusEnterClickCode(prefix: String) -> String {
        """
        el.focus();
        el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
        el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
        el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
        return '\(prefix):'+el.tagName+':'+text;
        """
    }

    private static func clickCodeFor(type: String, prefix: String) -> String {
        switch type {
        case "native": return nativeClickCode(prefix: prefix)
        case "humanTouch": return humanTouchClickCode(prefix: "HUMAN_CLICKED")
        case "pointer": return pointerClickCode(prefix: "POINTER_CLICKED")
        case "touch": return touchClickCode(prefix: "TOUCH_CLICKED")
        case "dispatch": return dispatchClickCode(prefix: "DISPATCH_CLICKED")
        case "mousedownUp": return mousedownUpClickCode(prefix: "MOUSEDOWN_CLICKED")
        case "focusEnter": return focusEnterClickCode(prefix: "ENTER_CLICKED")
        default: return nativeClickCode(prefix: prefix)
        }
    }

    // MARK: - Text-Based Login Button Search

    static func textSearchClickJS(clickType: String) -> String {
        let clickCode = clickCodeFor(type: clickType, prefix: "CLICKED")
        return """
        (function(){
            var terms=['log in','login','sign in','signin','submit','continue','next','go','enter'];
            var all=document.querySelectorAll('button,input[type="submit"],a,[role="button"],span,div,label');
            for(var i=0;i<all.length;i++){
                var el=all[i];
                var text=(el.textContent||el.value||'').replace(/[\\s]+/g,' ').toLowerCase().trim();
                if(text.length>50)continue;
                for(var t=0;t<terms.length;t++){
                    if(text===terms[t]||text.indexOf(terms[t])!==-1&&text.length<30){
                        try{el.scrollIntoView({behavior:'instant',block:'center'});
                        \(clickCode)
                        }catch(e){continue;}
                    }
                }
            }
            return 'NOT_FOUND';
        })()
        """
    }

    // MARK: - Button-Search-Then-Action Pattern

    private static func buttonSearchActionJS(action: String, resultPrefix: String) -> String {
        """
        (function(){
            var terms=['log in','login','sign in','signin','submit'];
            var btns=document.querySelectorAll('button,input[type="submit"],[role="button"]');
            for(var i=0;i<btns.length;i++){
                var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();
                var match=false;
                for(var t=0;t<terms.length;t++){
                    if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;
                }
                if(!match)continue;
                var el=btns[i];
                \(action)
                return '\(resultPrefix):'+el.tagName+':'+text;
            }
            return 'NOT_FOUND';
        })()
        """
    }

    // MARK: - Selector-Based Search JS

    private static func selectorSearchJS(selectors: [String], resultPrefix: String) -> String {
        let selsJS = selectors.map { "'\($0)'" }.joined(separator: ",")
        return """
        (function(){
            var sels=[\(selsJS)];
            for(var i=0;i<sels.length;i++){
                try{
                    var el=document.querySelector(sels[i]);
                    if(el){
                        el.scrollIntoView({behavior:'instant',block:'center'});
                        el.click();
                        return '\(resultPrefix):'+sels[i]+':'+el.tagName;
                    }
                }catch(e){}
            }
            return 'NOT_FOUND';
        })()
        """
    }

    // MARK: - Coordinate-Based JS

    private static func coordElementSetup(cx: Int, cy: Int) -> String {
        "var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';"
    }

    static func coordClickJS(cx: Int, cy: Int, clickType: String, name: String) -> String {
        let setup = coordElementSetup(cx: cx, cy: cy)
        switch clickType {
        case "native":
            return "(function(){\(setup)el.click();return'COORD_NATIVE:'+el.tagName+':'+(el.textContent||'').substring(0,20);})()"
        case "humanTouch":
            return "(function(){\(setup)el.focus();el.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse'}));el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:\(cx),clientY:\(cy)}));el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.click();return'COORD_HUMAN:'+el.tagName;})()"
        case "pointer":
            return "(function(){\(setup)el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'touch',button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'touch',button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy)}));return'COORD_POINTER:'+el.tagName;})()"
        case "touch":
            return "(function(){\(setup)try{var t=new Touch({identifier:Date.now(),target:el,clientX:\(cx),clientY:\(cy),pageX:\(cx)+window.scrollX,pageY:\(cy)+window.scrollY});el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));}catch(e){}el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy)}));el.click();return'COORD_TOUCH:'+el.tagName;})()"
        case "fullChain":
            return "(function(){\(setup)el.focus();['pointerover','pointerenter','pointermove','pointerdown'].forEach(function(e){el.dispatchEvent(new PointerEvent(e,{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0,buttons:1}));});['mouseover','mouseenter','mousemove','mousedown'].forEach(function(e){el.dispatchEvent(new MouseEvent(e,{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));});el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.click();return'COORD_FULL:'+el.tagName;})()"
        case "focusEnter":
            return "(function(){\(setup)el.focus();el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));return'COORD_ENTER:'+el.tagName;})()"
        case "mousedownUp":
            return "(function(){\(setup)el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));return'COORD_MDU:'+el.tagName;})()"
        case "dispatchAll":
            return "(function(){\(setup)el.disabled=false;el.removeAttribute('disabled');el.style.pointerEvents='auto';var r=el.getBoundingClientRect();el.focus();el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,detail:1,screenX:\(cx),screenY:\(cy),clientX:\(cx),clientY:\(cy),button:0}));try{el.click();}catch(e){}var form=el.closest('form');if(form){try{form.requestSubmit();}catch(e){try{form.submit();}catch(e2){}}}return'COORD_ALL:'+el.tagName;})()"
        case "cloneClick":
            return "(function(){\(setup)var clone=el.cloneNode(true);el.parentNode.replaceChild(clone,el);clone.click();return'COORD_CLONE:'+clone.tagName;})()"
        case "rafClick":
            return "(function(){\(setup)requestAnimationFrame(function(){el.click();el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy)}));});return'COORD_RAF:'+el.tagName;})()"
        default:
            return "(function(){\(setup)el.click();return'COORD:'+el.tagName;})()"
        }
    }

    // MARK: - Standalone Methods

    static let formRequestSubmitJS: String = """
        (function(){
            var forms=document.querySelectorAll('form');
            for(var i=0;i<forms.length;i++){
                if(forms[i].querySelector('input[type="password"]')){
                    try{forms[i].requestSubmit();return'REQUEST_SUBMIT_OK';}
                    catch(e){try{forms[i].submit();return'SUBMIT_OK';}catch(e2){}}
                }
            }
            return'NOT_FOUND';
        })()
        """

    static let formSubmitJS: String = """
        (function(){
            var forms=document.querySelectorAll('form');
            for(var i=0;i<forms.length;i++){
                if(forms[i].querySelector('input[type="password"]')){
                    try{forms[i].submit();return'FORM_SUBMIT_OK';}catch(e){}
                }
            }
            return'NOT_FOUND';
        })()
        """

    static let enterOnPasswordJS: String = """
        (function(){
            var el=document.querySelector('input[type="password"]');
            if(!el)return'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            return'ENTER_ON_PASS_OK';
        })()
        """

    static let enterOnEmailJS: String = """
        (function(){
            var el=document.querySelector('input[type="email"],input[type="text"],input[name="email"],input[name="username"]');
            if(!el)return'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            return'ENTER_ON_EMAIL_OK';
        })()
        """

    static let tabEnterFromPasswordJS: String = """
        (function(){
            var el=document.querySelector('input[type="password"]');
            if(!el)return'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true}));
            el.dispatchEvent(new KeyboardEvent('keyup',{key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true}));
            var next=document.activeElement;
            if(next&&next!==el){
                next.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                next.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                next.click();
                return'TAB_ENTER_OK:'+next.tagName;
            }
            return'TAB_NO_FOCUS_CHANGE';
        })()
        """

    static let submitButtonNativeJS: String = """
        (function(){
            var el=document.querySelector('button[type="submit"],input[type="submit"]');
            if(!el)return'NOT_FOUND';
            el.scrollIntoView({behavior:'instant',block:'center'});
            el.click();
            return'SUBMIT_BTN_NATIVE:'+el.tagName+':'+(el.textContent||el.value||'').substring(0,20);
        })()
        """

    static let submitButtonDispatchAllJS: String = """
        (function(){
            var el=document.querySelector('button[type="submit"],input[type="submit"]');
            if(!el)return'NOT_FOUND';
            var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
            el.focus();
            el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
            el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));
            el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
            el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            el.click();
            return'SUBMIT_DISPATCH:'+el.tagName;
        })()
        """

    static var ariaLabelClickJS: String {
        selectorSearchJS(
            selectors: [
                "[aria-label*=\"Log In\"]", "[aria-label*=\"Login\"]", "[aria-label*=\"Sign In\"]",
                "[aria-label*=\"log in\"]", "[aria-label*=\"login\"]", "[aria-label*=\"sign in\"]",
                "[aria-label*=\"submit\"]"
            ],
            resultPrefix: "ARIA_CLICKED"
        )
    }

    static var dataAttributeClickJS: String {
        selectorSearchJS(
            selectors: [
                "[data-action=\"login\"]", "[data-action=\"signin\"]", "[data-action=\"submit\"]",
                "[data-type=\"login\"]", "[data-type=\"submit\"]",
                "[data-testid*=\"login\"]", "[data-testid*=\"submit\"]",
                "[data-qa*=\"login\"]", "[data-qa*=\"submit\"]",
                "[data-cy*=\"login\"]", "[data-cy*=\"submit\"]"
            ],
            resultPrefix: "DATA_CLICKED"
        )
    }

    static let shadowDOMSearchJS: String = """
        (function(){
            function searchShadow(root,depth){
                if(depth>5)return null;
                var all=root.querySelectorAll('*');
                for(var i=0;i<all.length;i++){
                    if(all[i].shadowRoot){
                        var terms=['log in','login','sign in'];
                        var els=all[i].shadowRoot.querySelectorAll('button,a,[role="button"]');
                        for(var j=0;j<els.length;j++){
                            var text=(els[j].textContent||'').toLowerCase().trim();
                            for(var t=0;t<terms.length;t++){
                                if(text.indexOf(terms[t])!==-1&&text.length<30){
                                    els[j].click();
                                    return'SHADOW_CLICKED:'+els[j].tagName+':'+text;
                                }
                            }
                        }
                        var deeper=searchShadow(all[i].shadowRoot,depth+1);
                        if(deeper)return deeper;
                    }
                }
                return null;
            }
            var result=searchShadow(document,0);
            return result||'NOT_FOUND';
        })()
        """

    static let iframeSearchJS: String = """
        (function(){
            try{
                var iframes=document.querySelectorAll('iframe');
                for(var i=0;i<iframes.length;i++){
                    try{
                        var doc=iframes[i].contentDocument||iframes[i].contentWindow.document;
                        var terms=['log in','login','sign in'];
                        var els=doc.querySelectorAll('button,a,[role="button"],input[type="submit"]');
                        for(var j=0;j<els.length;j++){
                            var text=(els[j].textContent||els[j].value||'').toLowerCase().trim();
                            for(var t=0;t<terms.length;t++){
                                if(text.indexOf(terms[t])!==-1&&text.length<30){
                                    els[j].click();
                                    return'IFRAME_CLICKED:'+els[j].tagName+':'+text;
                                }
                            }
                        }
                    }catch(e){}
                }
            }catch(e){}
            return'NOT_FOUND';
        })()
        """

    static let nearPasswordButtonJS: String = """
        (function(){
            var pass=document.querySelector('input[type="password"]');
            if(!pass)return'NOT_FOUND';
            var parent=pass.parentElement;
            for(var d=0;d<8&&parent;d++){
                var btns=parent.querySelectorAll('button,[role="button"],a.btn,input[type="submit"]');
                for(var b=0;b<btns.length;b++){
                    if(btns[b].tagName==='INPUT'&&btns[b].type==='password')continue;
                    var text=(btns[b].textContent||btns[b].value||'').trim();
                    if(text.length<40){
                        btns[b].scrollIntoView({behavior:'instant',block:'center'});
                        btns[b].click();
                        return'NEAR_PASS_CLICKED:d='+d+':'+btns[b].tagName+':'+text.substring(0,20);
                    }
                }
                parent=parent.parentElement;
            }
            return'NOT_FOUND';
        })()
        """

    static let lastButtonInFormJS: String = """
        (function(){
            var forms=document.querySelectorAll('form');
            for(var i=0;i<forms.length;i++){
                if(forms[i].querySelector('input[type="password"]')){
                    var btns=forms[i].querySelectorAll('button,[role="button"],input[type="submit"]');
                    if(btns.length>0){
                        var last=btns[btns.length-1];
                        last.scrollIntoView({behavior:'instant',block:'center'});
                        last.click();
                        return'LAST_BTN_FORM:'+last.tagName+':'+(last.textContent||last.value||'').substring(0,20);
                    }
                }
            }
            return'NOT_FOUND';
        })()
        """

    static let spanDivRoleButtonJS: String = """
        (function(){
            var terms=['log in','login','sign in','signin','submit'];
            var els=document.querySelectorAll('span[role="button"],div[role="button"],label[role="button"]');
            for(var i=0;i<els.length;i++){
                var text=(els[i].textContent||'').toLowerCase().trim();
                for(var t=0;t<terms.length;t++){
                    if(text.indexOf(terms[t])!==-1&&text.length<30){
                        els[i].scrollIntoView({behavior:'instant',block:'center'});
                        els[i].click();
                        return'SPAN_DIV_CLICKED:'+els[i].tagName+':'+text;
                    }
                }
            }
            return'NOT_FOUND';
        })()
        """

    static let anchorTagClickJS: String = """
        (function(){
            var terms=['log in','login','sign in','signin','submit'];
            var els=document.querySelectorAll('a');
            for(var i=0;i<els.length;i++){
                var text=(els[i].textContent||'').toLowerCase().trim();
                for(var t=0;t<terms.length;t++){
                    if(text===terms[t]||text.indexOf(terms[t])!==-1&&text.length<20){
                        els[i].scrollIntoView({behavior:'instant',block:'center'});
                        els[i].click();
                        return'ANCHOR_CLICKED:'+text;
                    }
                }
            }
            return'NOT_FOUND';
        })()
        """

    static let imageButtonClickJS: String = """
        (function(){
            var els=document.querySelectorAll('input[type="image"],button img,a img');
            for(var i=0;i<els.length;i++){
                var el=els[i].tagName==='IMG'?els[i].parentElement:els[i];
                if(el){
                    var alt=(el.alt||el.title||el.getAttribute('aria-label')||'').toLowerCase();
                    if(alt.indexOf('login')!==-1||alt.indexOf('sign in')!==-1||alt.indexOf('submit')!==-1){
                        el.click();
                        return'IMG_BTN_CLICKED:'+alt.substring(0,20);
                    }
                }
            }
            return'NOT_FOUND';
        })()
        """

    static let svgButtonClickJS: String = """
        (function(){
            var btns=document.querySelectorAll('button,a,[role="button"]');
            for(var i=0;i<btns.length;i++){
                if(btns[i].querySelector('svg')){
                    var text=(btns[i].textContent||btns[i].getAttribute('aria-label')||'').toLowerCase().trim();
                    var terms=['log in','login','sign in','submit'];
                    for(var t=0;t<terms.length;t++){
                        if(text.indexOf(terms[t])!==-1){
                            btns[i].click();
                            return'SVG_BTN_CLICKED:'+text.substring(0,20);
                        }
                    }
                }
            }
            return'NOT_FOUND';
        })()
        """

    static let customElementClickJS: String = """
        (function(){
            var all=document.querySelectorAll('*');
            for(var i=0;i<all.length;i++){
                if(all[i].tagName.indexOf('-')!==-1){
                    var text=(all[i].textContent||'').toLowerCase().trim();
                    var terms=['log in','login','sign in','submit'];
                    for(var t=0;t<terms.length;t++){
                        if(text.indexOf(terms[t])!==-1&&text.length<30){
                            all[i].click();
                            return'CUSTOM_EL_CLICKED:'+all[i].tagName+':'+text.substring(0,20);
                        }
                    }
                }
            }
            return'NOT_FOUND';
        })()
        """

    static var fullEventChainAllButtonsJS: String {
        let action = """
            var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
            el.focus();
            ['pointerover','pointerenter','pointermove','pointerdown'].forEach(function(e){el.dispatchEvent(new PointerEvent(e,{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));});
            ['mouseover','mouseenter','mousemove','mousedown'].forEach(function(e){el.dispatchEvent(new MouseEvent(e,{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:e==='mousedown'?1:0}));});
            el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
            el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            el.click();
            """
        return buttonSearchActionJS(action: action, resultPrefix: "FULL_CHAIN_CLICKED")
    }

    static var simulateTrustedClickJS: String {
        let action = """
            el.scrollIntoView({behavior:'instant',block:'center'});
            var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
            var evt=new MouseEvent('click',{bubbles:true,cancelable:true,view:window,detail:1,screenX:cx,screenY:cy,clientX:cx,clientY:cy,ctrlKey:false,altKey:false,shiftKey:false,metaKey:false,button:0,relatedTarget:null});
            el.dispatchEvent(evt);
            """
        return buttonSearchActionJS(action: action, resultPrefix: "TRUSTED_CLICKED")
    }

    static var inputEventBurstJS: String {
        buttonSearchActionJS(
            action: "el.focus();el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));el.click();el.dispatchEvent(new Event('submit',{bubbles:true}));",
            resultPrefix: "INPUT_BURST_CLICKED"
        )
    }

    static var createClickOnDocumentJS: String {
        buttonSearchActionJS(
            action: "var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;document.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));el.click();",
            resultPrefix: "DOC_CLICK"
        )
    }

    static var requestAnimationFrameClickJS: String {
        buttonSearchActionJS(action: "requestAnimationFrame(function(){el.click();});", resultPrefix: "RAF_CLICKED")
    }

    static var mutationObserverClickJS: String {
        buttonSearchActionJS(
            action: "var observer=new MutationObserver(function(){observer.disconnect();});observer.observe(el,{attributes:true});el.click();",
            resultPrefix: "MUTATION_CLICKED"
        )
    }

    static var setTimeoutClickJS: String {
        buttonSearchActionJS(action: "setTimeout(function(){el.click();},0);", resultPrefix: "TIMEOUT_CLICKED")
    }

    static var doubleClickJS: String {
        buttonSearchActionJS(
            action: "el.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true}));el.click();",
            resultPrefix: "DBLCLICK_CLICKED"
        )
    }

    static var contextMenuClickJS: String {
        buttonSearchActionJS(
            action: "el.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));el.click();",
            resultPrefix: "CTX_CLICKED"
        )
    }

    static var removeDisabledClickJS: String {
        buttonSearchActionJS(
            action: "el.disabled=false;el.removeAttribute('disabled');el.style.pointerEvents='auto';el.style.opacity='1';el.click();",
            resultPrefix: "UNDISABLED_CLICKED"
        )
    }

    static var overridePreventDefaultJS: String {
        buttonSearchActionJS(
            action: "var clone=el.cloneNode(true);el.parentNode.replaceChild(clone,el);clone.click();",
            resultPrefix: "OVERRIDE_CLICKED"
        )
    }

    static var cloneReplaceButtonJS: String {
        buttonSearchActionJS(
            action: "var form=el.closest('form');if(form){try{form.requestSubmit();}catch(e){form.submit();}return'CLONE_FORM_SUBMIT:'+el.tagName+':'+text;}el.click();",
            resultPrefix: "CLONE_CLICKED"
        )
    }

    static let directFormActionJS: String = """
        (function(){
            var forms=document.querySelectorAll('form');
            for(var i=0;i<forms.length;i++){
                if(forms[i].querySelector('input[type="password"]')){
                    var action=forms[i].action||window.location.href;
                    var method=(forms[i].method||'POST').toUpperCase();
                    return'FORM_ACTION:'+method+':'+action;
                }
            }
            return'NOT_FOUND';
        })()
        """

    static let xhrFormPostJS: String = """
        (function(){
            var forms=document.querySelectorAll('form');
            for(var i=0;i<forms.length;i++){
                if(!forms[i].querySelector('input[type="password"]'))continue;
                var fd=new FormData(forms[i]);
                var action=forms[i].action||window.location.href;
                var xhr=new XMLHttpRequest();
                xhr.open('POST',action,true);
                xhr.withCredentials=true;
                xhr.onload=function(){document.open();document.write(xhr.responseText);document.close();};
                xhr.send(fd);
                return'XHR_POST_SENT:'+action;
            }
            return'NOT_FOUND';
        })()
        """

    static let fetchFormPostJS: String = """
        (function(){
            var forms=document.querySelectorAll('form');
            for(var i=0;i<forms.length;i++){
                if(!forms[i].querySelector('input[type="password"]'))continue;
                var fd=new FormData(forms[i]);
                var action=forms[i].action||window.location.href;
                fetch(action,{method:'POST',body:fd,credentials:'same-origin',redirect:'follow'})
                    .then(function(r){return r.text();})
                    .then(function(t){document.open();document.write(t);document.close();});
                return'FETCH_POST_SENT:'+action;
            }
            return'NOT_FOUND';
        })()
        """

    // MARK: - Method Registry Builders

    static func allTextBasedMethods() -> [ClickMethod] {
        let textClickTypes: [(String, String)] = [
            ("01_NativeClick_ExactText", "native"),
            ("02_HumanTouchChain_ExactText", "humanTouch"),
            ("03_PointerEvents_ExactText", "pointer"),
            ("04_TouchEvents_ExactText", "touch"),
            ("05_DispatchClick_ExactText", "dispatch"),
            ("06_MousedownUp_ExactText", "mousedownUp"),
            ("07_FocusThenEnter_ExactText", "focusEnter"),
        ]

        var methods: [ClickMethod] = textClickTypes.map { (name, type) in
            ClickMethod(name: name, js: textSearchClickJS(clickType: type))
        }

        methods.append(contentsOf: [
            ClickMethod(name: "08_FormRequestSubmit", js: formRequestSubmitJS),
            ClickMethod(name: "09_FormSubmit", js: formSubmitJS),
            ClickMethod(name: "10_EnterOnPassword", js: enterOnPasswordJS),
            ClickMethod(name: "11_EnterOnEmail", js: enterOnEmailJS),
            ClickMethod(name: "12_TabEnterFromPassword", js: tabEnterFromPasswordJS),
            ClickMethod(name: "13_SubmitButtonNativeClick", js: submitButtonNativeJS),
            ClickMethod(name: "14_SubmitButtonDispatchAll", js: submitButtonDispatchAllJS),
            ClickMethod(name: "15_AriaLabelClick", js: ariaLabelClickJS),
            ClickMethod(name: "16_DataAttributeClick", js: dataAttributeClickJS),
            ClickMethod(name: "17_ShadowDOMSearch", js: shadowDOMSearchJS),
            ClickMethod(name: "18_IframeSearch", js: iframeSearchJS),
            ClickMethod(name: "19_NearPasswordButtonClick", js: nearPasswordButtonJS),
            ClickMethod(name: "20_LastButtonInForm", js: lastButtonInFormJS),
            ClickMethod(name: "21_SpanDivRoleButton", js: spanDivRoleButtonJS),
            ClickMethod(name: "22_AnchorTagClick", js: anchorTagClickJS),
            ClickMethod(name: "23_ImageButtonClick", js: imageButtonClickJS),
            ClickMethod(name: "24_SVGButtonClick", js: svgButtonClickJS),
            ClickMethod(name: "25_CustomElementClick", js: customElementClickJS),
            ClickMethod(name: "26_FullEventChain_AllButtons", js: fullEventChainAllButtonsJS),
            ClickMethod(name: "27_SimulateTrustedClick", js: simulateTrustedClickJS),
            ClickMethod(name: "28_InputEventBurstOnButton", js: inputEventBurstJS),
            ClickMethod(name: "29_CreateClickOnDocument", js: createClickOnDocumentJS),
            ClickMethod(name: "30_RequestAnimationFrameClick", js: requestAnimationFrameClickJS),
            ClickMethod(name: "31_MutationObserverThenClick", js: mutationObserverClickJS),
            ClickMethod(name: "32_SetTimeoutClick", js: setTimeoutClickJS),
            ClickMethod(name: "33_DoubleClick", js: doubleClickJS),
            ClickMethod(name: "34_ContextMenuThenClick", js: contextMenuClickJS),
            ClickMethod(name: "35_RemoveDisabledThenClick", js: removeDisabledClickJS),
            ClickMethod(name: "36_OverridePreventDefault", js: overridePreventDefaultJS),
            ClickMethod(name: "37_CloneAndReplaceButton", js: cloneReplaceButtonJS),
            ClickMethod(name: "38_DirectHTMLFormAction", js: directFormActionJS),
            ClickMethod(name: "39_XHRFormPost", js: xhrFormPostJS),
            ClickMethod(name: "40_FetchFormPost", js: fetchFormPostJS),
        ])

        return methods
    }

    static func locationBasedMethods(cx: Int, cy: Int) -> [ClickMethod] {
        let coordClickTypes: [(String, String)] = [
            ("L01_CoordNativeClick", "native"),
            ("L02_CoordHumanTouch", "humanTouch"),
            ("L03_CoordPointerEvents", "pointer"),
            ("L04_CoordTouchEvents", "touch"),
            ("L05_CoordFullChain", "fullChain"),
            ("L06_CoordFocusEnter", "focusEnter"),
            ("L07_CoordMousedownUpClick", "mousedownUp"),
            ("L08_CoordDispatchAllEvents", "dispatchAll"),
            ("L09_CoordRemoveListenerClick", "cloneClick"),
            ("L10_CoordRAFClick", "rafClick"),
        ]
        return coordClickTypes.map { (name, type) in
            ClickMethod(name: name, js: coordClickJS(cx: cx, cy: cy, clickType: type, name: name))
        }
    }

    static let buttonStateCheckJS: String = """
        (function(){
            var terms=['log in','login','sign in','signin','submit'];
            var btns=document.querySelectorAll('button,input[type="submit"],a,[role="button"]');
            for(var i=0;i<btns.length;i++){
                var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();
                var isLogin=false;
                for(var t=0;t<terms.length;t++){
                    if(text.indexOf(terms[t])!==-1&&text.length<30)isLogin=true;
                }
                if(!isLogin&&btns[i].type!=='submit')continue;
                var style=window.getComputedStyle(btns[i]);
                var opacity=parseFloat(style.opacity);
                var disabled=btns[i].disabled;
                var hasSpinner=btns[i].querySelector('.spinner,.loading,[class*="spin"],[class*="load"]')!==null;
                var loading=btns[i].classList.toString().toLowerCase();
                if(opacity<0.85||disabled||hasSpinner||loading.indexOf('loading')!==-1||loading.indexOf('disabled')!==-1){
                    return'CHANGED:opacity='+opacity+',disabled='+disabled+',spinner='+hasSpinner;
                }
            }
            return'UNCHANGED';
        })()
        """
}
