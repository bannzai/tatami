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
      // 送信時に報告するパスワード欄。変更フォーム (現在・新規・確認) では新しいパスワード (autocomplete=new-password) を優先する
      const passwordFieldToReport = (scope) => {
        const fields = Array.from(scope.querySelectorAll('input[type="password"]'));
        return fields.find((field) => (field.autocomplete || '').toLowerCase() === 'new-password') || fields[0] || null;
      };
      const capture = (scope) => {
        const passwordField = passwordFieldToReport(scope);
        if (!passwordField || !passwordField.value) {
          // ユーザー名だけのページ (複数段階ログインの 1 段目) はユーザー名を覚えておく
          const usernameOnly = Array.from(scope.querySelectorAll('input')).find((input) => /username|email|user|login|account/i.test(`${input.autocomplete} ${input.name} ${input.id} ${input.type}`) && input.value);
          if (usernameOnly) {
            try { window.webkit.messageHandlers.tatamiLoginForm.postMessage({ usernameOnly: usernameOnly.value }); } catch (e) {}
          }
          return;
        }
        const usernameField = findUsernameField(passwordField);
        const isNewPassword = (passwordField.autocomplete || '').toLowerCase() === 'new-password'
          || (passwordField.form ? passwordField.form.querySelectorAll('input[type="password"]').length : 0) >= 2;
        try {
          window.webkit.messageHandlers.tatamiLoginForm.postMessage({
            submitted: true,
            username: usernameField ? usernameField.value : '',
            password: passwordField.value,
            isNewPassword,
            frameURL: location.href,
          });
        } catch (e) {}
      };
      document.addEventListener('submit', (event) => {
        const form = event.target;
        if (form && form.querySelector) { capture(form); }
      }, true);
      // 送信になりうるボタンだけを対象にする (type=button のパスワード表示切替などで入力途中の値を送らない)
      document.addEventListener('click', (event) => {
        const button = event.target && event.target.closest ? event.target.closest('button:not([type="button"]), input[type="submit"]') : null;
        if (!button) { return; }
        capture(button.form || button.closest('form') || document);
      }, true);
      // Web ページ内のテキスト入力中かをネイティブへ知らせる (入力中は提案の y / n を横取りしない)
      const isTextTarget = (element) => !!element && (element.isContentEditable || ['INPUT', 'TEXTAREA'].includes(element.tagName));
      const postEditing = () => {
        try { window.webkit.messageHandlers.tatamiLoginForm.postMessage({ editing: isTextTarget(document.activeElement) }); } catch (e) {}
      };
      document.addEventListener('focusin', postEditing, true);
      document.addEventListener('focusout', () => setTimeout(postEditing, 0), true);
      postEditing();
      document.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && event.target && event.target.type === 'password') { capture(event.target.form || document); }
      }, true);
      // サインアップ / パスワード変更フォーム (autocomplete=new-password か、パスワード欄が 2 つ以上) を検出して知らせる
      const postNewPassword = () => {
        const fields = Array.from(document.querySelectorAll('input[type="password"]'));
        const hasNewPassword = fields.some((field) => (field.autocomplete || '').toLowerCase() === 'new-password') || fields.length >= 2;
        try { window.webkit.messageHandlers.tatamiLoginForm.postMessage({ hasNewPassword }); } catch (e) {}
      };
      // SPA が既存の input の type / autocomplete を後から変える場合も検出する
      new MutationObserver(postNewPassword).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'autocomplete'] });
      postNewPassword();
      // 生成したパスワードは新規 (autocomplete=new-password) と確認の欄だけに入れ、現在のパスワード欄 (current-password) は保持する
      window.__tatamiFillNewPassword = (password) => {
        const visible = Array.from(document.querySelectorAll('input[type="password"]')).filter((field) => isVisible(field) && !field.disabled && !field.readOnly);
        const marked = visible.filter((field) => (field.autocomplete || '').toLowerCase() === 'new-password');
        const fields = marked.length > 0 ? marked : visible.filter((field) => (field.autocomplete || '').toLowerCase() !== 'current-password');
        if (fields.length === 0) { return false; }
        fields.forEach((field) => setValue(field, password));
        return true;
      };
      window.__tatamiFill = (username, password) => {
        // 登録・変更フォームの新規パスワード欄 (autocomplete=new-password) には既存のパスワードを入れない。current-password を優先する
        const fields = Array.from(document.querySelectorAll('input[type="password"]'))
          .filter((field) => (field.autocomplete || '').toLowerCase() !== 'new-password');
        // 可視で操作できる欄だけを対象にする。非表示の欄 (honeypot 等) へ充填するとページのスクリプトに平文を渡してしまう
        const usable = fields.filter((field) => isVisible(field) && !field.disabled && !field.readOnly);
        const passwordField = usable.find((field) => (field.autocomplete || '').toLowerCase() === 'current-password') || usable[0];
        if (!passwordField) { return false; }
        const usernameField = findUsernameField(passwordField);
        if (usernameField && username) { setValue(usernameField, username); }
        setValue(passwordField, password);
        passwordField.focus();
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
