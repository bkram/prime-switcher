# Honor CI's selected Xcode. Use full Xcode if only CLT is selected locally.
SELECTED_DEVELOPER_DIR := $(shell xcode-select -p)
ifneq ($(findstring CommandLineTools,$(SELECTED_DEVELOPER_DIR)),)
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
SELECTED_DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
endif
export DEVELOPER_DIR ?= $(SELECTED_DEVELOPER_DIR)

APP_NAME := PrimeSwitcher
JOBS ?= 10
APP_BUNDLE := dist/Prime\ Switcher.app
DMG := dist/PrimeSwitcher.dmg

.PHONY: build run clean dist dmg reset-permissions

build:
	swift build -j $(JOBS)
	@echo ""
	@echo "Build complete."
	@echo "Next steps:"
	@echo "  make run    - Run Prime Switcher"
	@echo "  make clean  - Clean build artifacts"
	@echo "  make dist   - Build Prime Switcher.app in dist/"
	@echo "  make dmg    - Build unsigned DMG in dist/"

run:
	swift run -j $(JOBS) $(APP_NAME)

clean:
	swift package clean

dist:
	./Scripts/make-app-bundle.sh

dmg:
	./Scripts/make-dmg.sh

reset-permissions:
	@tccutil reset Microphone com.mrk.primeswitcher || true
	@tccutil reset AudioCapture com.mrk.primeswitcher || true
	@echo "Reset microphone and system audio permissions for Prime Switcher."

.PHONY: test lint check

test:
	swift test --enable-code-coverage

lint:
	swiftlint lint --strict --no-cache

check: lint
	swift build
	swift test --enable-code-coverage
	swift build -c release
