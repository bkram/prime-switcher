APP_NAME := Input-to-Output-Monitor
JOBS ?= 10
APP_BUNDLE := dist/Input-to-Output\ Monitor.app
DMG := dist/InputToOutputMonitor.dmg

.PHONY: build run clean dist dmg reset-permissions

build:
	swift build -j $(JOBS)
	@echo ""
	@echo "Build complete."
	@echo "Next steps:"
	@echo "  make run    - Run the app"
	@echo "  make clean  - Clean build artifacts"
	@echo "  make dist   - Build .app bundle in dist/"
	@echo "  make dmg    - Build unsigned DMG in dist/"

run:
	swift run -j $(JOBS)

clean:
	swift package clean

dist:
	./Scripts/make-app-bundle.sh

dmg:
	./Scripts/make-dmg.sh

reset-permissions:
	@tccutil reset Microphone "Input-to-Output Monitor" || true
	@tccutil reset Microphone com.mrk.inputtooutputmonitor || true
	@tccutil reset Microphone com.apple.Terminal || true
	@echo "Reset microphone permissions for Input-to-Output Monitor and Terminal."
