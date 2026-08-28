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
      const post = () => {
        const hasPassword = !!document.querySelector('input[type="password"]');
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
        const passwordField = Array.from(document.querySelectorAll('input[type="password"]')).find(isVisible)
          || document.querySelector('input[type="password"]');
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
