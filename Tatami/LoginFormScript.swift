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
      // 同じ URL の iframe が複数あっても区別できるよう、注入されたコンテキストごとに一意な ID を全ての通知に付ける
      const frameID = Math.random().toString(36).slice(2) + Date.now().toString(36);
      const send = (body) => { try { window.webkit.messageHandlers.tatamiLoginForm.postMessage(Object.assign({ frameID }, body)); } catch (e) {} };
      // DOM の変化のたびに送るとチャット等で IPC が続くため、有無が変わった時だけ送る
      let lastHasPassword = null;
      const post = () => {
        const hasPassword = !!document.querySelector('input[type="password"]');
        if (hasPassword === lastHasPassword) { return; }
        lastHasPassword = hasPassword;
        send({ hasPassword });
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
      // ログインフォームの送信 (submit イベント、または XHR / fetch でログインするページのために送信ボタンのクリックと
      // パスワード欄での Enter) を検出し、その時点のユーザー名・パスワードをネイティブへ渡す
      // 送信時に報告するパスワード欄。変更フォーム (現在・新規・確認) では新しいパスワード (autocomplete=new-password) を優先する
      // 可視で操作できる欄だけを対象にする (非表示の honeypot や無効化された欄を送信値として扱わない)
      const usablePasswordFields = (scope) => Array.from(scope.querySelectorAll('input[type="password"]'))
        .filter((field) => isVisible(field) && !field.disabled && !field.readOnly);
      const passwordFieldToReport = (scope) => {
        const fields = usablePasswordFields(scope);
        return fields.find((field) => (field.autocomplete || '').toLowerCase() === 'new-password') || fields[0] || null;
      };
      // 変更フォームで既存の項目を特定するための現在のパスワード (autocomplete=current-password か、新規の欄より前の欄)
      const currentPasswordValue = (scope, reported) => {
        const fields = usablePasswordFields(scope);
        const current = fields.find((field) => (field.autocomplete || '').toLowerCase() === 'current-password')
          || fields.find((field) => field !== reported && (field.autocomplete || '').toLowerCase() !== 'new-password');
        return current && current !== reported ? current.value : '';
      };
      const capture = (scope) => {
        const passwordField = passwordFieldToReport(scope);
        if (!passwordField || !passwordField.value) {
          // ユーザー名だけのページ (複数段階ログインの 1 段目) はユーザー名を覚えておく
          // hidden の内部 ID (account_id 等) を拾わないよう、通常のユーザー名検出と同じく可視で操作できる text / email 系の欄に限る
          const usernameOnly = inputsIn(scope).find((input) => {
            const type = (input.getAttribute('type') || 'text').toLowerCase();
            return ['text', 'email', 'tel', 'username'].includes(type) && !input.disabled && !input.readOnly && isVisible(input)
              && /username|email|user|login|account/i.test(`${input.autocomplete} ${input.name} ${input.id} ${input.type}`) && input.value;
          });
          if (usernameOnly) {
            send({ usernameOnly: usernameOnly.value });
          }
          return;
        }
        const usernameField = findUsernameField(passwordField);
        const isNewPassword = (passwordField.autocomplete || '').toLowerCase() === 'new-password'
          || (passwordField.form ? Array.from(passwordField.form.querySelectorAll('input[type="password"]')).filter(isVisible).length : 0) >= 2;
        try {
          send({
            submitted: true,
            username: usernameField ? usernameField.value : '',
            password: passwordField.value,
            currentPassword: isNewPassword ? currentPasswordValue(scope, passwordField) : '',
            isNewPassword,
            frameURL: location.href,
          });
        } catch (e) {}
      };
      document.addEventListener('submit', (event) => {
        const form = event.target;
        if (form && form.querySelector) { capture(form); }
      }, true);
      // 制約検証 (required / pattern 等) で送信されないクリック・Enter は通知しない (通常のフォームは submit イベント側で捕捉する)
      const passesValidation = (form, button) => !form || form.noValidate || (button && button.formNoValidate) || typeof form.checkValidity !== 'function' || form.checkValidity();
      // 送信になりうるボタンだけを対象にする (type=button のパスワード表示切替などで入力途中の値を送らない)
      document.addEventListener('click', (event) => {
        const button = event.target && event.target.closest ? event.target.closest('button:not([type="button"]):not([type="reset"]), input[type="submit"]') : null;
        if (!button) { return; }
        const form = button.form || button.closest('form');
        if (!passesValidation(form, button)) { return; }
        capture(form || document);
      }, true);
      // Web ページ内のテキスト入力中かをネイティブへ知らせる (入力中は提案の y / n を横取りしない)
      const isTextTarget = (element) => !!element && (element.isContentEditable || ['INPUT', 'TEXTAREA'].includes(element.tagName));
      const postEditing = () => {
        send({ editing: isTextTarget(document.activeElement) });
      };
      document.addEventListener('focusin', postEditing, true);
      document.addEventListener('focusout', () => setTimeout(postEditing, 0), true);
      postEditing();
      document.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && event.target && event.target.type === 'password' && passesValidation(event.target.form, null)) { capture(event.target.form || document); }
      }, true);
      // サインアップ / パスワード変更フォーム (autocomplete=new-password か、パスワード欄が 2 つ以上) を検出して知らせる
      // 複数欄の判定は同じ (可視の) フォーム内の組で行う (デスクトップ用・モバイル用に独立したログインフォームが並ぶページを誤検出しない)。
      // 状態が変わった時だけ送る
      const isNewPasswordForm = (scope) => {
        // 送信・充填側と同じく操作できる欄だけで判定する (表示用の disabled / readOnly の欄を 2 つ目と数えない)
        const fields = usablePasswordFields(scope);
        return fields.some((field) => (field.autocomplete || '').toLowerCase() === 'new-password') || fields.length >= 2;
      };
      let lastHasNewPassword = null;
      const postNewPassword = () => {
        const scopes = Array.from(document.querySelectorAll('form'));
        const hasNewPassword = scopes.some(isNewPasswordForm)
          || isNewPasswordForm({ querySelectorAll: (selector) => Array.from(document.querySelectorAll(selector)).filter((field) => !field.form) });
        if (hasNewPassword === lastHasNewPassword) { return; }
        lastHasNewPassword = hasNewPassword;
        send({ hasNewPassword });
      };
      // SPA が既存の input の type / autocomplete を後から変える場合も検出する
      new MutationObserver(postNewPassword).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'autocomplete'] });
      postNewPassword();
      // 生成したパスワードは新規 (autocomplete=new-password) と確認の欄だけに入れ、現在のパスワード欄 (current-password) は保持する
      window.__tatamiFillNewPassword = (password) => {
        const visible = Array.from(document.querySelectorAll('input[type="password"]')).filter((field) => isVisible(field) && !field.disabled && !field.readOnly);
        const marked = visible.filter((field) => (field.autocomplete || '').toLowerCase() === 'new-password');
        // 新規の欄が印付きでも、同じフォームの確認欄 (印無し) にも同じ値を入れる。現在のパスワード欄だけを除外する
        const notCurrent = visible.filter((field) => (field.autocomplete || '').toLowerCase() !== 'current-password');
        const fields = marked.length > 0
          ? notCurrent.filter((field) => marked.includes(field) || marked.some((m) => m.form === field.form))
          : notCurrent;
        if (fields.length === 0) { return false; }
        fields.forEach((field) => setValue(field, password));
        return true;
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
