.PHONY: check test static build app check-release

SWIFT_CACHE := $(CURDIR)/.swift-cache

check: test static build

test:
	CLANG_MODULE_CACHE_PATH=$(SWIFT_CACHE)/clang swift run --package-path . LocalDictationCoreChecks

static:
	@for file in Sources/LocalDictationCore/*.swift Sources/LocalDictationApp/*.swift Sources/LocalDictationCoreChecks/*.swift; do \
		swiftc -frontend -parse "$$file" || exit 1; \
	done
	plutil -lint Info.plist
	bash -n scripts/build-app.sh
	bash -n scripts/release.sh
	bash -n scripts/release-smoke-test.sh

build:
	CLANG_MODULE_CACHE_PATH=$(SWIFT_CACHE)/clang swift build --package-path . -c release

app: build
	bash scripts/build-app.sh

check-release:
	bash scripts/release.sh --self-test
	bash scripts/release-smoke-test.sh --self-test
