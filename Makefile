XCODEPROJ := Tatami.xcodeproj
SCHEME := Tatami
CONFIGURATION := Debug
# システムの DerivedData を汚さず、成果物のパスを決定的にするためリポジトリ内に置く
DERIVED_DATA := tmp/DerivedData
# macos target の target 固有変数 CONFIGURATION を反映するため遅延展開にする
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Tatami.app
INSTALL_APP := /Applications/Tatami.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# CI (署名なし) では CODE_SIGNING_ALLOWED=NO を渡す。ローカルでは空のまま自動署名し、
# provisioning profile の自動生成とこの Mac のデバイス登録を CLI からも行えるようにする
CODE_SIGNING_ALLOWED :=
SIGNING_FLAGS = $(if $(CODE_SIGNING_ALLOWED),CODE_SIGNING_ALLOWED=$(CODE_SIGNING_ALLOWED),-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
XCODEBUILD_FLAGS = -project $(XCODEPROJ) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' $(SIGNING_FLAGS)

.PHONY: build-macos macos test clean

# ログは全文を tmp/ に保存し、終了後に warning / error の行を切り詰めずに表示する (AGENTS.md「検証方法」)。
# xcodebuild の終了ステータスは pipefail で受け取る。warning はビルドを失敗にしないが、報告に含めるために列挙する
define run_xcodebuild_with_log
	mkdir -p tmp
	set -o pipefail; xcodebuild $(XCODEBUILD_FLAGS) $(1) 2>&1 | tee $(2)
	@echo "--- warning / error in $(2) ---"
	@grep -i -e 'warning:' -e 'error:' $(2) || true
endef

# macOS アプリのビルドだけを行う (配置・起動はしない)
build-macos:
	$(call run_xcodebuild_with_log,build,tmp/build.log)

# Release ビルドを /Applications に配置して普段使いできるようにする (target の内容は macos-install-app skill の生成物と同じ)
macos: CONFIGURATION := Release
macos: build-macos
	rm -rf $(INSTALL_APP)
	ditto $(APP) $(INSTALL_APP)
	$(LSREGISTER) -f $(INSTALL_APP)

test:
	$(call run_xcodebuild_with_log,test,tmp/test.log)

clean:
	rm -rf $(DERIVED_DATA)
