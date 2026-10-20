# Use the full Xcode toolchain when available; the CLT SDK may not match Swift.
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

APP_NAME := Input-to-Output-Monitor
JOBS ?= 10
APP_BUNDLE := dist/Input-to-Output\ Monitor.app
ROUTER_BUNDLE := dist/Application\ Audio\ Router.app
DMG := dist/InputToOutputMonitor.dmg

.PHONY: build run run-router clean dist dmg reset-permissions

build:
	swift build -j $(JOBS)
	@echo ""
	@echo "Build complete."
	@echo "Next steps:"
	@echo "  make run    - Run Input-to-Output Monitor"
	@echo "  make run-router - Run Application Audio Router"
	@echo "  make clean  - Clean build artifacts"
	@echo "  make dist   - Build both .app bundles in dist/"
	@echo "  make dmg    - Build unsigned DMG in dist/"

run:
	swift run -j $(JOBS)

run-router:
	swift run -j $(JOBS) $(APP_NAME) --router

clean:
	swift package clean

dist:
	./Scripts/make-app-bundle.sh

dmg:
	./Scripts/make-dmg.sh

reset-permissions:
	@tccutil reset Microphone "Input-to-Output Monitor" || true
	@tccutil reset Microphone com.mrk.inputtooutputmonitor || true
	@tccutil reset AudioCapture com.mrk.applicationaudiorouter || true
	@tccutil reset Microphone com.apple.Terminal || true
	@tccutil reset AudioCapture com.apple.Terminal || true
	@echo "Reset microphone and system audio permissions for both apps and Terminal."

.PHONY: test lint check

test:
	swift test --enable-code-coverage

lint:
	swiftlint lint --strict --no-cache

check: lint
	swift build
	swift test --enable-code-coverage
	swift build -c release
