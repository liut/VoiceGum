PRODUCT_NAME = VoiceGum
BUNDLE_ID = com.voicegum.app
DEVELOPER_ID = $$(security find-identity -v -s "Developer ID Application" 2>/dev/null | grep "Developer ID Application" | grep -oE '[A-F0-9]{40}' | head -1)
NOTARY_PROFILE = NotaryProfile
VERSION = 1.0.0
BUILD_PATH = .build/release
RELEASE_APP_PATH = build/Release/VoiceGum.app

.PHONY: all build run run-cli run-app install install-cli clean sign notarize pkg bundle

all: build

build:
	swift build -c release

run:
	./$(BUILD_PATH)/VoiceGum

run-cli:
	./$(BUILD_PATH)/VoiceGumCLI

install-cli: build
	cp $(BUILD_PATH)/VoiceGumCLI /usr/local/bin/voicegum-cli

bundle: build
	rm -rf $(RELEASE_APP_PATH)
	mkdir -p $(RELEASE_APP_PATH)/Contents/MacOS $(RELEASE_APP_PATH)/Contents/Resources
	cp $(BUILD_PATH)/VoiceGum $(RELEASE_APP_PATH)/Contents/MacOS/
	cp -r $(BUILD_PATH)/VoiceGum_VoiceGum.bundle $(RELEASE_APP_PATH)/Contents/Resources/
	cp Resources/Info.plist $(RELEASE_APP_PATH)/Contents/Info.plist
	cp Resources/AppIcon.icns $(RELEASE_APP_PATH)/Contents/Resources/
	cp -r Resources/Assets.xcassets $(RELEASE_APP_PATH)/Contents/Resources/

run-app: bundle
	pkill -f VoiceGum 2>/dev/null || true
	codesign --sign - --force --options runtime $(RELEASE_APP_PATH)
	open $(RELEASE_APP_PATH)

sign: bundle
	@if [ -z "$(DEVELOPER_ID)" ]; then \
		echo "No Developer ID cert, using ad-hoc sign for local use"; \
		codesign --sign - --force --options runtime $(RELEASE_APP_PATH); \
	else \
		codesign --force --sign "$(DEVELOPER_ID)" --options runtime $(RELEASE_APP_PATH); \
	fi

notarize: sign
	@if ! xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
		echo "Notary profile not found. Set it up first:"; \
		echo "  xcrun notarytool store-credentials \"$(NOTARY_PROFILE)\""; \
		echo "    --apple-id <your-apple-id> --team-id <team-id>"; \
		exit 1; \
	fi
	ditto -c -k --keepParent $(RELEASE_APP_PATH) $(BUILD_PATH)/VoiceGum.zip
	xcrun notarytool submit $(BUILD_PATH)/VoiceGum.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(RELEASE_APP_PATH)
	@echo "Done. Verify with: spctl -a -vvv $(RELEASE_APP_PATH)"

install: notarize
	rm -rf /Applications/VoiceGum.app
	cp -r $(RELEASE_APP_PATH) /Applications/

pkg: bundle

clean:
	rm -rf .build build
