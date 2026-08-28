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
      new MutationObserver(post).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld)
    }
}
