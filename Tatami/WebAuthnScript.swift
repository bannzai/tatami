import Foundation
import WebKit

/// `navigator.credentials` をページの world で置き換え、create / get を `tatamiWebAuthn` の (返信付き) message handler へ転送する注入スクリプト。
/// ArrayBuffer は base64url の文字列にして渡し、返ってきた文字列を ArrayBuffer に戻して PublicKeyCredential 相当のオブジェクトを組み立てる
enum WebAuthnScript {
    static let messageName = "tatamiWebAuthn"

    static let source = """
    (() => {
      if (navigator.__tatamiWebAuthn) { return; }
      navigator.__tatamiWebAuthn = true;
      const encode = (buffer) => btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
      const decode = (text) => {
        let base64 = text.replace(/-/g, '+').replace(/_/g, '/');
        base64 += '='.repeat((4 - base64.length % 4) % 4);
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
        return bytes.buffer;
      };
      const toBuffer = (value) => {
        if (value instanceof ArrayBuffer) { return value; }
        if (ArrayBuffer.isView(value)) { return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength); }
        if (typeof value === 'string') { return decode(value); }
        return null;
      };
      const encodeOptional = (value) => { const buffer = toBuffer(value); return buffer ? encode(buffer) : null; };
      const domException = (reply) => new DOMException(reply.error || 'WebAuthn request failed', reply.name || 'NotAllowedError');
      // ネイティブの prototype (PublicKeyCredential 等) を継承させつつ、id / response などは自前の own property にする
      // (prototype の getter はネイティブのインスタンスにしか使えず、代入では上書きできないため defineProperty で定義する)
      const attach = (target, prototype) => {
        const object = Object.create(prototype || Object.prototype);
        for (const key of Object.keys(target)) {
          Object.defineProperty(object, key, { value: target[key], enumerable: true, configurable: true, writable: true });
        }
        return object;
      };
      const makeCredential = (reply, isCreate) => {
        const rawId = decode(reply.id);
        const clientDataJSON = decode(reply.clientDataJSON);
        const authenticatorData = decode(reply.authenticatorData);
        const response = isCreate
          ? attach({
              clientDataJSON,
              attestationObject: decode(reply.attestationObject),
              getTransports: () => ['internal'],
              getAuthenticatorData: () => authenticatorData,
              getPublicKey: () => decode(reply.publicKeyDER),
              getPublicKeyAlgorithm: () => -7,
            }, window.AuthenticatorAttestationResponse ? AuthenticatorAttestationResponse.prototype : null)
          : attach({
              clientDataJSON,
              authenticatorData,
              signature: decode(reply.signature),
              userHandle: reply.userHandle ? decode(reply.userHandle) : null,
            }, window.AuthenticatorAssertionResponse ? AuthenticatorAssertionResponse.prototype : null);
        const credential = attach({
          id: reply.id,
          rawId,
          type: 'public-key',
          authenticatorAttachment: 'platform',
          response,
          getClientExtensionResults: () => ({}),
          toJSON: () => ({
            id: reply.id,
            rawId: reply.id,
            type: 'public-key',
            authenticatorAttachment: 'platform',
            clientExtensionResults: {},
            response: isCreate
              ? { clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject, authenticatorData: reply.authenticatorData, publicKey: reply.publicKeyDER, publicKeyAlgorithm: -7, transports: ['internal'] }
              : { clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature, userHandle: reply.userHandle || null },
          }),
        }, window.PublicKeyCredential ? PublicKeyCredential.prototype : null);
        return credential;
      };
      const original = navigator.credentials;
      // AbortSignal: 開始時点で abort 済みなら要求せず、待機中に abort されたら AbortError で終える
      // (ネイティブ側の本人確認は取り消せないため、その結果は捨てる)
      const request = async (body, signal) => {
        if (signal && signal.aborted) { throw new DOMException('The operation was aborted.', 'AbortError'); }
        const native = window.webkit.messageHandlers.tatamiWebAuthn.postMessage(body);
        const reply = await (signal
          ? Promise.race([native, new Promise((_, reject) => signal.addEventListener('abort', () => reject(new DOMException('The operation was aborted.', 'AbortError')), { once: true }))])
          : native);
        if (!reply || reply.error) { throw domException(reply || {}); }
        return reply;
      };
      const shim = {
        create: async (options) => {
          const publicKey = options && options.publicKey;
          if (!publicKey) { return original.create(options); }
          const reply = await request({
            op: 'create',
            rpId: publicKey.rp && publicKey.rp.id ? publicKey.rp.id : null,
            rpName: publicKey.rp && publicKey.rp.name ? publicKey.rp.name : '',
            userId: encodeOptional(publicKey.user.id),
            userName: publicKey.user.name || '',
            userDisplayName: publicKey.user.displayName || '',
            challenge: encodeOptional(publicKey.challenge),
            algorithms: (publicKey.pubKeyCredParams || []).map((param) => param.alg),
            excludeCredentials: (publicKey.excludeCredentials || []).map((item) => encodeOptional(item.id)).filter(Boolean),
            userVerification: (publicKey.authenticatorSelection && publicKey.authenticatorSelection.userVerification) || 'preferred',
            authenticatorAttachment: (publicKey.authenticatorSelection && publicKey.authenticatorSelection.authenticatorAttachment) || null,
          }, options.signal);
          return makeCredential(reply, true);
        },
        get: async (options) => {
          const publicKey = options && options.publicKey;
          if (!publicKey) { return original.get(options); }
          if (options.mediation === 'silent') {
            // silent は利用者の操作を求めてはいけない。この authenticator は本人確認なしに assertion を返さないため、
            // プロンプトを出さず「候補なし」の標準的な結果 (null) で完了する
            return null;
          }
          if (options.mediation === 'conditional') {
            // 入力欄の自動入力候補 (conditional UI) には対応しない。ページはこの拒否を受けて通常のボタン経由へ進む
            throw new DOMException('conditional mediation is not supported', 'NotSupportedError');
          }
          const reply = await request({
            op: 'get',
            rpId: publicKey.rpId || null,
            challenge: encodeOptional(publicKey.challenge),
            allowCredentials: (publicKey.allowCredentials || []).map((item) => encodeOptional(item.id)).filter(Boolean),
            userVerification: publicKey.userVerification || 'preferred',
          }, options.signal);
          return makeCredential(reply, false);
        },
        preventSilentAccess: () => original.preventSilentAccess(),
        store: (credential) => original.store(credential),
      };
      Object.defineProperty(navigator, 'credentials', { value: shim, configurable: true });
      const PublicKeyCredentialClass = window.PublicKeyCredential || function PublicKeyCredential() {};
      PublicKeyCredentialClass.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(true);
      PublicKeyCredentialClass.isConditionalMediationAvailable = () => Promise.resolve(false);
      if (!window.PublicKeyCredential) { window.PublicKeyCredential = PublicKeyCredentialClass; }
    })();
    """

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }
}
