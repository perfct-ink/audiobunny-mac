APP_NAME       := AudioBunny

DEBUG_BIN      := .build/debug/$(APP_NAME)
RELEASE_BIN    := .build/release/$(APP_NAME)
DEBUG_BUNDLE   := .build/debug/$(APP_NAME).app
RELEASE_BUNDLE := .build/release/$(APP_NAME).app
INSTALL_PATH   := /Applications/$(APP_NAME).app

# VST2Prober is built universal (arm64 + x86_64) so it can dlopen Intel-only
# VST2 plugins under Rosetta as well as native arm64 ones — see PluginManager's
# VST2 category probing.
# Ask SwiftPM for the output directory; it varies by build system/toolchain.
VST2PROBER_DEBUG   = $$(swift build -c debug --arch arm64 --arch x86_64 --product VST2Prober --show-bin-path)/VST2Prober
VST2PROBER_RELEASE = $$(swift build -c release --arch arm64 --arch x86_64 --product VST2Prober --show-bin-path)/VST2Prober

.PHONY: all dev build clean open close install uninstall reinstall \
        test test-stress help
.DEFAULT_GOAL := all

# ── Default ───────────────────────────────────────────────────────────────────

all: dev

# ── Development ───────────────────────────────────────────────────────────────

dev:
	@echo "▸ Killing any running $(APP_NAME)…"
	-killall "$(APP_NAME)" 2>/dev/null
	@rm -rf $(DEBUG_BUNDLE)
	@echo "▸ Building $(APP_NAME) (debug)…"
	swift build -c debug
	@echo "▸ Building VST2Prober (universal)…"
	swift build -c debug --arch arm64 --arch x86_64 --product VST2Prober
	@mkdir -p $(DEBUG_BUNDLE)/Contents/MacOS $(DEBUG_BUNDLE)/Contents/Resources
	@cp $(DEBUG_BIN) $(DEBUG_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(VST2PROBER_DEBUG) $(DEBUG_BUNDLE)/Contents/MacOS/VST2Prober
	@cp Info.plist $(DEBUG_BUNDLE)/Contents/Info.plist
	@cp AppIcon.icns $(DEBUG_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp -R .build/debug/$(APP_NAME)_$(APP_NAME).bundle $(DEBUG_BUNDLE)/Contents/Resources/
	open $(DEBUG_BUNDLE)

# ── Production ────────────────────────────────────────────────────────────────

build:
	@echo "▸ Building $(APP_NAME) (release)…"
	swift build -c release
	@echo "▸ Building VST2Prober (universal)…"
	swift build -c release --arch arm64 --arch x86_64 --product VST2Prober
	@mkdir -p $(RELEASE_BUNDLE)/Contents/MacOS $(RELEASE_BUNDLE)/Contents/Resources
	@cp $(RELEASE_BIN) $(RELEASE_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(VST2PROBER_RELEASE) $(RELEASE_BUNDLE)/Contents/MacOS/VST2Prober
	@cp Info.plist $(RELEASE_BUNDLE)/Contents/Info.plist
	@cp AppIcon.icns $(RELEASE_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp -R .build/release/$(APP_NAME)_$(APP_NAME).bundle $(RELEASE_BUNDLE)/Contents/Resources/

open:
	@killall "$(APP_NAME)" 2>/dev/null || true
	open $(RELEASE_BUNDLE)

close:
	-killall "$(APP_NAME)" 2>/dev/null

# ── Install ───────────────────────────────────────────────────────────────────

install: build
	-killall "$(APP_NAME)" 2>/dev/null
	@cp -R $(RELEASE_BUNDLE) $(INSTALL_PATH)
	@echo "▸ Installed to $(INSTALL_PATH)"
	open $(INSTALL_PATH)

uninstall: close
	@rm -rf $(INSTALL_PATH)
	@echo "▸ Uninstalled $(APP_NAME)"

reinstall: uninstall install

# ── Testing ───────────────────────────────────────────────────────────────────
# make test is the default pre-commit/pre-request check: build + unit tests
# only (seconds). The launch stress test is slow (relaunches the app 8x) and
# is for specifically tracking down startup/scanning crashes — run it
# explicitly via `make test-stress`, not as part of routine testing.

test:
	@echo "▸ Building $(APP_NAME) (debug)…"
	swift build -c debug
	@echo "▸ Running unit tests…"
	swift test

test-stress: test
	@echo "▸ Running launch stress test…"
	scripts/stress_test.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean:
	@rm -rf .build
	@echo "▸ Cleaned build artifacts"

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  Development"
	@echo "    make              Build debug + open app  (= make all = make dev)"
	@echo "    make dev          Build debug, delete old bundle, open app"
	@echo ""
	@echo "  Production"
	@echo "    make build        Build release bundle"
	@echo "    make open         Open existing release bundle"
	@echo "    make close        Kill the running app"
	@echo ""
	@echo "  Install"
	@echo "    make install      Build release + copy to /Applications + open"
	@echo "    make uninstall    Kill app + remove from /Applications"
	@echo "    make reinstall    uninstall + install"
	@echo ""
	@echo "  Testing"
	@echo "    make test         Build + unit tests (used by the pre-commit hook)"
	@echo "    make test-stress  test + launch stress test (slow; run explicitly)"
	@echo ""
	@echo "  Cleanup"
	@echo "    make clean        Remove all build artifacts"
	@echo ""
	@echo "  Web app moved to ~/Sites/audiobunny-web — see that repo's Makefile."
