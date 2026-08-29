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
        // 充填できる欄 (new-password だけのフォームは対象外) があるフレームだけを充填先の候補として知らせる
        const hasPassword = Array.from(document.querySelectorAll('input[type="password"]')).some((field) => !hasAutocomplete(field, 'new-password'));
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
      // 描画されているか (検出用。スクロールで画面外にあっても数える)
      const isRendered = (element) => {
        const rect = element.getBoundingClientRect();
        if (!(rect.width > 0 && rect.height > 0)) { return false; }
        if (typeof element.checkVisibility === 'function') {
          return element.checkVisibility({ visibilityProperty: true, opacityProperty: true });
        }
        return getComputedStyle(element).visibility !== 'hidden' && getComputedStyle(element).opacity !== '0';
      };
      // 充填してよいか (描画されていて、かつビューポートと交差している。画面外に配置した honeypot に平文を入れない)
      const isVisible = (element) => {
        if (!isRendered(element)) { return false; }
        const rect = element.getBoundingClientRect();
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
      const usablePasswordFields = (scope) => inputsIn(scope).filter((field) => (field.getAttribute('type') || '').toLowerCase() === 'password')
        .filter((field) => isVisible(field) && !field.matches(':disabled') && !field.readOnly);
      // 検出用 (画面外でも数える)
      const renderedPasswordFields = (scope) => inputsIn(scope).filter((field) => (field.getAttribute('type') || '').toLowerCase() === 'password')
        .filter((field) => isRendered(field) && !field.matches(':disabled') && !field.readOnly);
      // autocomplete の無い「現在・新規・確認」の 3 欄の変更フォームでは、末尾 2 欄の値が一致すればその前の欄を現在、2 番目を新規とみなす
      const isUnmarkedChangeForm = (fields) => fields.length >= 3 && !fields.some((field) => hasAutocomplete(field, 'new-password') || hasAutocomplete(field, 'current-password'))
        && fields[fields.length - 2].value === fields[fields.length - 1].value;
      const passwordFieldToReport = (scope) => {
        const fields = usablePasswordFields(scope);
        if (isUnmarkedChangeForm(fields)) { return fields[fields.length - 2]; }
        return fields.find((field) => hasAutocomplete(field, 'new-password')) || fields[0] || null;
      };
      // 変更フォームで既存の項目を特定するための現在のパスワード (autocomplete=current-password か、新規の欄より前の欄)
      const currentPasswordValue = (scope, reported) => {
        const fields = usablePasswordFields(scope);
        if (isUnmarkedChangeForm(fields)) { return fields[fields.length - 3].value; }
        const current = fields.find((field) => hasAutocomplete(field, 'current-password'))
          || fields.find((field) => field !== reported && !hasAutocomplete(field, 'new-password'));
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
        // form 属性で関連付けた欄も数えるため、フォームでは elements から列挙する (画面外でも数える)
        const isNewPassword = hasAutocomplete(passwordField, 'new-password')
          || (passwordField.form ? renderedPasswordFields(passwordField.form).length : 0) >= 2;
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
      // 破棄される iframe (削除・再読み込み) は false 通知を送れないため、pagehide でこのフレームの状態を全て消してもらう
      window.addEventListener('pagehide', () => send({ gone: true }));
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
        // 送信・充填側と同じく操作できる欄だけで判定する (表示用の disabled / readOnly の欄を 2 つ目と数えない)。画面外でも検出する
        const fields = renderedPasswordFields(scope);
        return fields.some((field) => hasAutocomplete(field, 'new-password')) || fields.length >= 2;
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
      // class / style の変更はアニメーション等で頻発するため、連続する変更を 1 回の再評価にまとめる (レイアウト計算を毎回走らせない)
      let newPasswordTimer = null;
      const scheduleNewPassword = () => {
        if (newPasswordTimer !== null) { return; }
        newPasswordTimer = setTimeout(() => { newPasswordTimer = null; postNewPassword(); }, 100);
      };
      new MutationObserver(scheduleNewPassword).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'autocomplete', 'class', 'style', 'hidden'] });
      postNewPassword();
      // 生成したパスワードは新規 (autocomplete=new-password) と確認の欄だけに入れ、現在のパスワード欄 (current-password) は保持する
      window.__tatamiFillNewPassword = (password) => {
        // 生成値は新規パスワードフォームと判定したフォーム (form 要素、または form に属さない欄の組) の欄にだけ入れる
        // (同じ文書に並ぶ通常のログインフォームの入力済みパスワードを上書きしない)。現在のパスワード欄は保持する
        const collect = () => {
          const scopes = Array.from(document.querySelectorAll('form')).filter(isNewPasswordForm);
          const formless = { querySelectorAll: (selector) => Array.from(document.querySelectorAll(selector)).filter((field) => !field.form) };
          if (isNewPasswordForm(formless)) { scopes.push(formless); }
          return scopes.flatMap((scope) => {
            const usable = usablePasswordFields(scope);
            // autocomplete の無い「現在・新規・確認」のフォームでは現在の欄 (末尾から 3 つ目) を保持する
            const current = isUnmarkedChangeForm(usable) ? usable[usable.length - 3] : null;
            return usable.filter((field) => field !== current && !hasAutocomplete(field, 'current-password'));
          });
        };
        const fields = collect();
        if (fields.length === 0) { return false; }
        // input / change でフォームを再生成するページでは、先に入れた欄のイベントで残りの欄が DOM から外れることがあるため、
        // 1 欄ごとに接続状態を確かめ、外れていれば入れ直す対象を再探索する
        const filled = new Set();
        for (let i = 0; i < 8; i++) {
          const remaining = collect().filter((field) => field.isConnected && !filled.has(field) && field.value !== password);
          if (remaining.length === 0) { break; }
          setValue(remaining[0], password);
          filled.add(remaining[0]);
        }
        return filled.size > 0;
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
      // Back/Forward Cache から復元されたページは pagehide で状態を消した後、初期化が再実行されないため、現在の状態を送り直す
      window.addEventListener('pageshow', (event) => {
        if (!event.persisted) { return; }
        lastHasPassword = null;
        lastHasNewPassword = null;
        post();
        postNewPassword();
        postEditing();
      });
    })();
    """

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld)
    }
}
