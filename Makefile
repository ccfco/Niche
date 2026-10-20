# 提交门禁:快速、无网络、不改源码(前提:SPM 依赖已解析过一次)。
# 由 scripts/git-hooks/pre-commit 调用;首次克隆后执行 `make install-hooks` 挂上 hook。
.PHONY: check install-hooks

check:
	xcodegen generate
	xcodebuild -scheme Niche -destination 'platform=macOS,arch=arm64' \
		-disableAutomaticPackageResolution -testLanguage zh-Hans -testRegion CN test

install-hooks:
	ln -sf ../../scripts/git-hooks/pre-commit .git/hooks/pre-commit