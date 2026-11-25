APP_NAME      := LynxBar
SCHEME        := LynxBar
CONFIGURATION ?= Debug
BUILD_DIR     := build
ARCHIVE       := $(BUILD_DIR)/$(APP_NAME).xcarchive
EXPORT_DIR    := $(BUILD_DIR)/export

.PHONY: all generate build test run clean archive export release-help

all: build

generate:
	xcodegen generate

build: generate
	set -o pipefail && xcodebuild \
		-project $(APP_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'generic/platform=macOS' \
		CODE_SIGNING_ALLOWED=NO \
		build | tail -5

test: generate
	set -o pipefail && xcodebuild \
		-project $(APP_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO \
		test

run: build
	@open "$$(find ~/Library/Developer/Xcode/DerivedData -name $(APP_NAME).app -path '*Debug*' | head -1)"

clean:
	rm -rf $(BUILD_DIR) $(APP_NAME).xcodeproj

# Archive and export (requires TEAM_ID in exportOptions.plist plus APPLE_ID / APP_PASSWORD
# in environment variables). See scripts/release.sh for the full notarized release flow.
archive: generate
	set -o pipefail && xcodebuild \
		-project $(APP_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-archivePath $(ARCHIVE) \
		archive | tail -5

export: archive
	set -o pipefail && xcodebuild \
		-archivePath $(ARCHIVE) \
		-exportArchive \
		-exportOptionsPlist exportOptions.plist \
		-exportPath $(EXPORT_DIR) | tail -5
	@echo "==> Export complete: $(EXPORT_DIR)/$(APP_NAME).app"

release-help:
	@echo "See scripts/release.sh for the full release pipeline. Required:"
	@echo "  1) Substitute teamID in exportOptions.plist (or pass TEAM_ID to scripts/release.sh)"
	@echo "  2) Environment variables APPLE_ID, TEAM_ID, and APP_PASSWORD"
