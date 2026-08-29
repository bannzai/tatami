import WebKit

/// ログインフォームの検出と充填を行う JavaScript。Web ページから改変されないよう専用の WKContentWorld で実行する
/// (macOS の WKWebView では OS の Password AutoFill が無効のため、充填は自前で行う。documents/PROJECT.md 技術リスク)
enum LoginFormScript {
    /// 注入スクリプトを実行する world。ページの JavaScript から `window` の関数を書き換えられない
    static let contentWorld = WKContentWorld.world(name: "tatami")
    /// ログインフォームの有無をネイティブへ知らせるメッセージ名
    static let messageName = "tatamiLoginForm"

    /// documentStart・全フレームで注入し、パスワード欄の出現を監視して `tatamiLoginForm` を送る。
    /// `__tatamiFill` は充填の入口で、React 等が値の変化を拾えるよう native setter で値を入れて input / change を発火する
    static let source = """
    (() => {
      // DOM の変化のたびに送るとチャット等で IPC が続くため、有無が変わった時だけ送る
      let lastHasPassword = null;
      const post = () => {
        // 充填できる欄 (new-password だけのフォームは対象外) があるフレームだけを充填先の候補として知らせる
        const hasPassword = Array.from(document.querySelectorAll('input[type="password"]')).some((field) => !hasAutocomplete(field, 'new-password'));
        if (hasPassword === lastHasPassword) { return; }
        lastHasPassword = hasPassword;
        try { window.webkit.messageHandlers.tatamiLoginForm.postMessage({ hasPassword }); } catch (e) {}
      };
      const setValue = (element, value) => {
        const prototype = Object.getPrototypeOf(element);
        const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
        if (descriptor && descriptor.set) { descriptor.set.call(element, value); } else { element.value = value; }
        element.dispatchEvent(new Event('input', { bubbles: true }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
      };
      // 祖先を含む実際の表示状態で判定する (opacity: 0 や visibility: hidden の honeypot に平文を入れない)
      const isVisible = (element) => {
        const rect = element.getBoundingClientRect();
        if (!(rect.width > 0 && rect.height > 0)) { return false; }
        // 画面外 (left: -10000px 等) の honeypot に平文を入れないよう、ビューポートと交差していることも要求する
        if (rect.right <= 0 || rect.bottom <= 0 || rect.left >= window.innerWidth || rect.top >= window.innerHeight) { return false; }
        if (typeof element.checkVisibility === 'function') {
          return element.checkVisibility({ visibilityProperty: true, opacityProperty: true });
        }
        return getComputedStyle(element).visibility !== 'hidden' && getComputedStyle(element).opacity !== '0';
      };
      // autocomplete は空白区切りのトークン列 (`section-signup new-password` 等) なので、値全体ではなくトークンで判定する
      const hasAutocomplete = (field, token) => (field.autocomplete || field.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/).includes(token);
      // form 属性で関連付けられた (DOM 上はフォームの子孫でない) 欄も含めるため、フォームでは elements を使う
      const inputsIn = (scope) => Array.from(scope.elements ? scope.elements : scope.querySelectorAll('input')).filter((element) => element.tagName === 'INPUT');
      const findUsernameField = (passwordField) => {
        const form = passwordField.form || document;
        const candidates = inputsIn(form).filter((input) => {
          const type = (input.getAttribute('type') || 'text').toLowerCase();
          return ['text', 'email', 'tel', 'username'].includes(type) && !input.matches(':disabled') && !input.readOnly && isVisible(input);
        });
        const explicit = candidates.find((input) => /username|email|user|login|account|id/i.test(`${input.autocomplete} ${input.name} ${input.id}`));
        if (explicit) { return explicit; }
        const before = candidates.filter((input) => input.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING);
        return before[before.length - 1] || candidates[0] || null;
      };
      window.__tatamiFill = (username, password) => {
        // 登録・変更フォームの新規パスワード欄 (autocomplete=new-password) には既存のパスワードを入れない。current-password を優先する
        const fields = Array.from(document.querySelectorAll('input[type="password"]'))
          .filter((field) => !hasAutocomplete(field, 'new-password'));
        // 可視で操作できる欄だけを対象にする。非表示の欄 (honeypot 等) へ充填するとページのスクリプトに平文を渡してしまう
        const usable = fields.filter((field) => isVisible(field) && !field.matches(':disabled') && !field.readOnly);
        const passwordField = usable.find((field) => hasAutocomplete(field, 'current-password')) || usable[0];
        if (!passwordField) { return false; }
        const usernameField = findUsernameField(passwordField);
        if (usernameField && username) { setValue(usernameField, username); }
        // ユーザー名の input / change でフォームを再描画するページでは、保持していたパスワード欄が DOM から外れていることがあるため再探索する
        const target = passwordField.isConnected ? passwordField : (usable.find((field) => field.isConnected) || null);
        if (!target || !target.isConnected) { return false; }
        setValue(target, password);
        target.focus();
        return true;
      };
      post();
      // 既存の input の type を後から password に変えるページも検出する
      new MutationObserver(post).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type'] });
    })();
    """

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld)
    }
}
