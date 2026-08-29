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
        // 実際に充填できる欄 (充填時と同じ条件: new-password でなく、可視で操作できる) があるフレームだけを充填先の候補として知らせる
        const hasPassword = !!findFillablePasswordField();
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
      // form の無い UI では、クリック処理が渡した区画 (scope) の中からユーザー名欄を探す (別区画のメール欄を拾わない)
      // requireViewport=false は送信時の値の読み取り用 (画面外へスクロールした欄も含める)。true は充填先の選定用 (honeypot を避ける)
      const findUsernameField = (passwordField, scope, requireViewport) => {
        const form = passwordField.form || scope || document;
        const shown = requireViewport ? isVisible : isRendered;
        const candidates = inputsIn(form).filter((input) => {
          const type = (input.getAttribute('type') || 'text').toLowerCase();
          return ['text', 'email', 'tel', 'username'].includes(type) && !input.matches(':disabled') && !input.readOnly && shown(input);
        });
        // autocomplete=username / email の明示を最優先し、次に名前・id の語で探す (`id` は tenant-id 等に部分一致しないよう語として扱う)
        const marked = candidates.find((input) => hasAutocomplete(input, 'username') || hasAutocomplete(input, 'email'));
        if (marked) { return marked; }
        const explicit = candidates.find((input) => /username|email|user|login|account|(^|[^a-z])id($|[^a-z])/i.test(`${input.name} ${input.id}`));
        if (explicit) { return explicit; }
        const before = candidates.filter((input) => input.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING);
        return before[before.length - 1] || candidates[0] || null;
      };
      // ログインフォームの送信 (submit イベント、または XHR / fetch でログインするページのために送信ボタンのクリックと
      // パスワード欄での Enter) を検出し、その時点のユーザー名・パスワードをネイティブへ渡す
      // 送信時に報告するパスワード欄。変更フォーム (現在・新規・確認) では新しいパスワード (autocomplete=new-password) を優先する
      // 可視で操作できる欄だけを対象にする (非表示の honeypot や無効化された欄を送信値として扱わない)
      // type=password の欄と、パスワード表示ボタンで text に変わったが autocomplete でパスワード用途と分かる欄
      const isPasswordField = (field) => {
        const type = (field.getAttribute('type') || 'text').toLowerCase();
        return type === 'password' || (type === 'text' && (hasAutocomplete(field, 'current-password') || hasAutocomplete(field, 'new-password')));
      };
      // ユーザー名だけの段階で覚えておく候補 (可視で操作できる text / email 系で、名前がユーザー名らしく値が入っている欄)
      const usernameCandidate = (scope) => inputsIn(scope).find((input) => {
        const type = (input.getAttribute('type') || 'text').toLowerCase();
        return ['text', 'email', 'tel', 'username'].includes(type) && !input.disabled && !input.readOnly && isVisible(input)
          && /username|email|user|login|account/i.test(`${input.autocomplete} ${input.name} ${input.id} ${input.type}`) && input.value;
      });
      const usablePasswordFields = (scope) => inputsIn(scope).filter(isPasswordField)
        .filter((field) => isVisible(field) && !field.matches(':disabled') && !field.readOnly);
      // 検出用 (画面外でも数える)
      const renderedPasswordFields = (scope) => inputsIn(scope).filter(isPasswordField)
        .filter((field) => isRendered(field) && !field.matches(':disabled') && !field.readOnly);
      // autocomplete も無い変更フォームで、欄の名前から現在のパスワード欄を見分ける (current / old / 現在 / 旧)
      const looksLikeCurrentPassword = (field) => /current|old|existing|現在|旧/i.test(`${field.name} ${field.id} ${field.placeholder} ${field.getAttribute('aria-label') || ''}`);
      // autocomplete の無い変更フォームで新規パスワード欄と現在のパスワード欄を返す (判定できなければ new のみ)。
      // 3 欄以上で末尾 2 欄の値が一致する (現在・新規・確認) か、2 欄で先頭が「現在」と読める (現在・新規) 場合を変更フォームとみなす
      const unmarkedChangeFields = (fields) => {
        if (fields.some((field) => hasAutocomplete(field, 'new-password') || hasAutocomplete(field, 'current-password'))) { return null; }
        if (fields.length >= 3 && fields[fields.length - 2].value === fields[fields.length - 1].value) {
          return { new: fields[fields.length - 2], current: fields[fields.length - 3] };
        }
        if (fields.length === 2 && looksLikeCurrentPassword(fields[0]) && !looksLikeCurrentPassword(fields[1])) {
          return { new: fields[1], current: fields[0] };
        }
        return null;
      };
      const passwordFieldToReport = (scope) => {
        // 送信値の読み取りは画面外へスクロールした欄も含める (充填時の honeypot 対策のビューポート判定は使わない)
        const fields = renderedPasswordFields(scope);
        const change = unmarkedChangeFields(fields);
        if (change) { return change.new; }
        return fields.find((field) => hasAutocomplete(field, 'new-password')) || fields[0] || null;
      };
      // 変更フォームで既存の項目を特定するための現在のパスワード (autocomplete=current-password か、名前で見分けた現在の欄、または新規の欄より前の欄)
      const currentPasswordValue = (scope, reported) => {
        const fields = renderedPasswordFields(scope);
        const change = unmarkedChangeFields(fields);
        if (change) { return change.current.value; }
        const current = fields.find((field) => hasAutocomplete(field, 'current-password'))
          || fields.find((field) => field !== reported && !hasAutocomplete(field, 'new-password'));
        return current && current !== reported ? current.value : '';
      };
      // 同じ送信をクリック / Enter と submit の両方で通知しない (2 回目の通知で保留ユーザー名を失い、空ユーザー名の提案で上書きしないため)
      let lastCapture = { key: null, at: 0 };
      // scope から送信内容を組み立てる (送信はしない)。ユーザー名だけの段階は { usernameOnly } を返す
      const collectSubmission = (scope) => {
        const passwordField = passwordFieldToReport(scope);
        if (!passwordField || !passwordField.value) {
          const usernameOnly = usernameCandidate(scope);
          return usernameOnly ? { usernameOnly: usernameOnly.value } : null;
        }
        const usernameField = findUsernameField(passwordField, scope, false);
        const isNewPassword = hasAutocomplete(passwordField, 'new-password')
          || renderedPasswordFields(passwordField.form || scope).length >= 2;
        return {
          submitted: true,
          username: usernameField ? usernameField.value : '',
          password: passwordField.value,
          currentPassword: isNewPassword ? currentPasswordValue(scope, passwordField) : '',
          isNewPassword,
          frameURL: location.href,
        };
      };
      const notify = (payload) => {
        if (!payload) { return; }
        if (payload.submitted) {
          const key = `${payload.password.length}:${payload.password}`;
          const now = Date.now();
          if (lastCapture.key === key && now - lastCapture.at < 1000) { return; }
          lastCapture = { key, at: now };
        }
        try { send(payload); } catch (e) {}
      };
      const capture = (scope) => notify(collectSubmission(scope));
      // submit は送信時点の値を同期的に読んで通知する (ページが直後に欄を消しても回収できる)。
      // preventDefault は検証キャンセルと AJAX ログイン (React の preventDefault + fetch) の両方で使われ区別できないため、
      // defaultPrevented では捨てない。保存・更新の提案は非破壊 (y/n) で、誤って出ても n で消せる一方、実ログインの取りこぼしは避ける
      document.addEventListener('submit', (event) => {
        const form = event.target;
        if (!form || !form.querySelector) { return; }
        notify(collectSubmission(form));
      }, true);
      // 制約検証 (required / pattern 等) で送信されないクリック・Enter は通知しない (通常のフォームは submit イベント側で捕捉する)
      const passesValidation = (form, button) => !form || form.noValidate || (button && button.formNoValidate) || typeof form.checkValidity !== 'function' || form.checkValidity();
      // form の無い UI で、要素が属するログイン UI の区画 (dialog / section / main / fieldset 等)
      const loginScope = (element) => element.closest('dialog, [role="dialog"], form, section, article, main, aside, nav, fieldset') || null;
      // 送信になりうるボタンだけを対象にする (type=button のパスワード表示切替などで入力途中の値を送らない)
      document.addEventListener('click', (event) => {
        const button = event.target && event.target.closest ? event.target.closest('button:not([type="button"]):not([type="reset"]), input[type="submit"], [role="button"]') : null;
        if (!button) { return; }
        // フォーム所属の submitter (button / input[type=submit]) は native の submit イベントで捕捉するため、ここでは扱わない
        // (form 内の role=button の非送信ボタンを送信と誤認しない・submit との二重通知を避ける)
        if (button.form) { return; }
        // form の無いボタン (role=button の AJAX ログインを含む) は、パスワード欄かユーザー名候補を持つログイン区画のものだけ捕捉する
        const container = loginScope(button);
        if (!container || !(usablePasswordFields(container).length || usernameCandidate(container))) { return; }
        capture(container);
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
        // form 内の Enter は native の submit を発生させ submit イベントで捕捉するため、ここでは form の無い欄だけを扱う。
        // パスワード欄に加え、複数段階ログインの 1 段目 (ユーザー名だけの text / email 欄) からの Enter も捕捉する
        const target = event.target;
        if (event.key !== 'Enter' || !target || target.form) { return; }
        const type = (target.getAttribute && (target.getAttribute('type') || 'text').toLowerCase()) || '';
        if (isPasswordField(target) || ['text', 'email', 'tel', 'username'].includes(type)) {
          capture(loginScope(target) || document);
        }
      }, true);
      // サインアップ / パスワード変更フォーム (autocomplete=new-password か、パスワード欄が 2 つ以上) を検出して知らせる
      // 複数欄の判定は同じ (可視の) フォーム内の組で行う (デスクトップ用・モバイル用に独立したログインフォームが並ぶページを誤検出しない)。
      // 状態が変わった時だけ送る
      const isNewPasswordForm = (scope) => {
        // 送信・充填側と同じく操作できる欄だけで判定する (表示用の disabled / readOnly の欄を 2 つ目と数えない)。画面外でも検出する
        const fields = renderedPasswordFields(scope);
        return fields.some((field) => hasAutocomplete(field, 'new-password')) || fields.length >= 2;
      };
      // form に属さないパスワード欄は、属する区画 (dialog / section 等) ごとに 1 組として扱う (独立したログイン UI が 2 つ並ぶページを
      // 登録フォームと誤判定しない)。区画が無い欄は文書全体で 1 組
      const formlessScopes = () => {
        const groups = new Map();
        for (const field of inputsIn(document).filter((field) => isPasswordField(field) && !field.form)) {
          const container = loginScope(field) || document;
          if (!groups.has(container)) { groups.set(container, []); }
          groups.get(container).push(field);
        }
        return Array.from(groups.values()).map((fields) => ({ querySelectorAll: () => fields, elements: null }));
      };
      let lastHasNewPassword = null;
      const postNewPassword = () => {
        const scopes = Array.from(document.querySelectorAll('form'));
        const hasNewPassword = scopes.some(isNewPasswordForm) || formlessScopes().some(isNewPasswordForm);
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
      new MutationObserver(scheduleNewPassword).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'autocomplete', 'class', 'style', 'hidden', 'disabled', 'readonly'] });
      postNewPassword();
      // 生成したパスワードは新規 (autocomplete=new-password) と確認の欄だけに入れ、現在のパスワード欄 (current-password) は保持する
      window.__tatamiFillNewPassword = (password) => {
        // 生成値は新規パスワードフォームと判定したフォーム (form 要素、または form に属さない欄の組) の欄にだけ入れる
        // (同じ文書に並ぶ通常のログインフォームの入力済みパスワードを上書きしない)。現在のパスワード欄は保持する
        // 生成値を入れる対象は最初に見つかった 1 つの新規パスワードフォームだけ (別フォームの入力済み値を上書きしない)。
        // 画面外の確認欄も充填するため rendered を使い、現在のパスワード欄は除外し続ける
        const scope = Array.from(document.querySelectorAll('form')).filter(isNewPasswordForm).concat(formlessScopes().filter(isNewPasswordForm))[0];
        if (!scope) { return false; }
        const current = unmarkedChangeFields(renderedPasswordFields(scope))?.current || null;
        const targets = () => renderedPasswordFields(scope).filter((field) => field !== current && !hasAutocomplete(field, 'current-password'));
        if (targets().length === 0) { return false; }
        // input / change でフォームを再生成するページでは、先に入れた欄のイベントで残りの欄が DOM から外れることがあるため、
        // 1 欄ごとに接続状態を確かめ、外れていれば入れ直す対象を再探索する (現在の欄は毎回除外する)
        const filled = new Set();
        for (let i = 0; i < 8; i++) {
          const remaining = targets().filter((field) => field.isConnected && !filled.has(field) && field.value !== password);
          if (remaining.length === 0) { break; }
          setValue(remaining[0], password);
          filled.add(remaining[0]);
        }
        return filled.size > 0;
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
        const usernameField = findUsernameField(passwordField, null, true);
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
