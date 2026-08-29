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
        // 実際に充填できる欄 (充填時と同じ条件: new-password でなく、可視で操作できる) があるフレームだけを充填先の候補として知らせる
        const hasPassword = !!findFillablePasswordField();
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
        // autocomplete=username / email の明示を最優先し、次に名前・id の語で探す (`id` は tenant-id 等に部分一致しないよう語として扱う)
        const marked = candidates.find((input) => hasAutocomplete(input, 'username') || hasAutocomplete(input, 'email'));
        if (marked) { return marked; }
        const explicit = candidates.find((input) => /username|email|user|login|account|(^|[^a-z])id($|[^a-z])/i.test(`${input.name} ${input.id}`));
        if (explicit) { return explicit; }
        const before = candidates.filter((input) => input.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING);
        return before[before.length - 1] || candidates[0] || null;
      };
      // 充填できるパスワード欄 (現在の DOM から)。登録・変更フォームの新規パスワード欄 (autocomplete=new-password) には既存のパスワードを入れず、
      // current-password を優先する。可視で操作できる欄だけを対象にする (非表示の honeypot に平文を渡さない)
      const findFillablePasswordField = () => {
        const usable = Array.from(document.querySelectorAll('input[type="password"]'))
          .filter((field) => !hasAutocomplete(field, 'new-password') && isVisible(field) && !field.matches(':disabled') && !field.readOnly);
        return usable.find((field) => hasAutocomplete(field, 'current-password')) || usable[0];
      };
      window.__tatamiFill = (username, password) => {
        const passwordField = findFillablePasswordField();
        if (!passwordField) { return false; }
        const usernameField = findUsernameField(passwordField);
        if (usernameField && username) { setValue(usernameField, username); }
        // ユーザー名の input / change でフォームを再描画するページでは、保持していたパスワード欄が DOM から外れていることがあるため、
        // 現在の DOM から操作できる欄を探し直す
        const target = passwordField.isConnected ? passwordField : (findFillablePasswordField() || null);
        if (!target || !target.isConnected) { return false; }
        setValue(target, password);
        target.focus();
        return true;
      };
      post();
      // 既存の input の type を後から password に変えるページも検出する
      // 欄の有効化・表示の変化 (disabled / readonly / class / style / hidden) でも充填可否を再評価する。
      // class / style はアニメーション等で頻発するため、連続する変更を 1 回にまとめる (レイアウト計算を毎回走らせない)
      let postTimer = null;
      const schedulePost = () => {
        if (postTimer !== null) { return; }
        postTimer = setTimeout(() => { postTimer = null; post(); }, 100);
      };
      new MutationObserver(schedulePost).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'autocomplete', 'disabled', 'readonly', 'hidden', 'class', 'style'] });
    })();
    """

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld)
    }
}
