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
        const hasPassword = !!document.querySelector('input[type="password"]');
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
      const isVisible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== 'hidden';
      };
      const findUsernameField = (passwordField) => {
        const form = passwordField.form || document;
        const candidates = Array.from(form.querySelectorAll('input')).filter((input) => {
          const type = (input.getAttribute('type') || 'text').toLowerCase();
          return ['text', 'email', 'tel', 'username'].includes(type) && !input.disabled && !input.readOnly && isVisible(input);
        });
        const explicit = candidates.find((input) => /username|email|user|login|account|id/i.test(`${input.autocomplete} ${input.name} ${input.id}`));
        if (explicit) { return explicit; }
        const before = candidates.filter((input) => input.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING);
        return before[before.length - 1] || candidates[0] || null;
      };
      // ログインフォームの送信 (submit イベント、または XHR / fetch でログインするページのために送信ボタンのクリックと
      // パスワード欄での Enter) を検出し、その時点のユーザー名・パスワードをネイティブへ渡す
      const capture = (passwordField) => {
        if (!passwordField || !passwordField.value) { return; }
        const usernameField = findUsernameField(passwordField);
        const isNewPassword = (passwordField.autocomplete || '').toLowerCase() === 'new-password'
          || (passwordField.form ? passwordField.form.querySelectorAll('input[type="password"]').length : 0) >= 2;
        try {
          window.webkit.messageHandlers.tatamiLoginForm.postMessage({
            submitted: true,
            username: usernameField ? usernameField.value : '',
            password: passwordField.value,
            isNewPassword,
          });
        } catch (e) {}
      };
      document.addEventListener('submit', (event) => {
        const form = event.target;
        if (form && form.querySelector) { capture(form.querySelector('input[type="password"]')); }
      }, true);
      document.addEventListener('click', (event) => {
        const button = event.target && event.target.closest ? event.target.closest('button, input[type="submit"], [role="button"]') : null;
        if (!button) { return; }
        const scope = button.form || button.closest('form') || document;
        capture(scope.querySelector('input[type="password"]'));
      }, true);
      document.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && event.target && event.target.type === 'password') { capture(event.target); }
      }, true);
      // サインアップ / パスワード変更フォーム (autocomplete=new-password か、パスワード欄が 2 つ以上) を検出して知らせる
      const postNewPassword = () => {
        const fields = Array.from(document.querySelectorAll('input[type="password"]'));
        const hasNewPassword = fields.some((field) => (field.autocomplete || '').toLowerCase() === 'new-password') || fields.length >= 2;
        try { window.webkit.messageHandlers.tatamiLoginForm.postMessage({ hasNewPassword }); } catch (e) {}
      };
      new MutationObserver(postNewPassword).observe(document.documentElement, { childList: true, subtree: true });
      postNewPassword();
      window.__tatamiFillNewPassword = (password) => {
        const fields = Array.from(document.querySelectorAll('input[type="password"]')).filter(isVisible);
        if (fields.length === 0) { return false; }
        fields.forEach((field) => setValue(field, password));
        return true;
      };
      window.__tatamiFill = (username, password) => {
        // 登録・変更フォームの新規パスワード欄 (autocomplete=new-password) には既存のパスワードを入れない。current-password を優先する
        const fields = Array.from(document.querySelectorAll('input[type="password"]'))
          .filter((field) => (field.autocomplete || '').toLowerCase() !== 'new-password');
        const passwordField = fields.find((field) => (field.autocomplete || '').toLowerCase() === 'current-password' && isVisible(field))
          || fields.find(isVisible) || fields[0];
        if (!passwordField) { return false; }
        const usernameField = findUsernameField(passwordField);
        if (usernameField && username) { setValue(usernameField, username); }
        setValue(passwordField, password);
        passwordField.focus();
        return true;
      };
      post();
      new MutationObserver(post).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld)
    }
}
