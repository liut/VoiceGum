PRODUCT_NAME = VoiceGum
BUNDLE_ID = com.voicegum.app
DEVELOPER_ID = $$(security find-identity -v -s "Developer ID Application" 2>/dev/null | grep -oE '[A-F0-9]{40}' | head -1)
VERSION = 1.0.0
BUILD_PATH = .build/release
RELEASE_APP_PATH = build/Release/VoiceGum.app

.PHONY: all build run run-app install clean sign

all: build

build:
	swift build -c release

run:
	./$(BUILD_PATH)/VoiceGum

run-app: build
	pkill -f VoiceGum 2>/dev/null || true
	rm -rf $(RELEASE_APP_PATH)
	mkdir -p $(RELEASE_APP_PATH)/Contents/MacOS $(RELEASE_APP_PATH)/Contents/Resources
	cp $(BUILD_PATH)/VoiceGum $(RELEASE_APP_PATH)/Contents/MacOS/
	cp -r $(BUILD_PATH)/VoiceGum_VoiceGum.bundle $(RELEASE_APP_PATH)/Contents/Resources/
	cp Resources/Info.plist $(RELEASE_APP_PATH)/Contents/Info.plist
	open $(RELEASE_APP_PATH)

install: build sign
	rm -rf /Applications/VoiceGum.app
	cp -r build/Release/VoiceGum.app /Applications/

sign:
	rm -rf build/Release/VoiceGum.app
	mkdir -p build/Release/VoiceGum.app/Contents/MacOS
	mkdir -p build/Release/VoiceGum.app/Contents/Resources
	cp $(BUILD_PATH)/VoiceGum build/Release/VoiceGum.app/Contents/MacOS/
	cp -r $(BUILD_PATH)/VoiceGum_VoiceGum.bundle build/Release/VoiceGum.app/Contents/Resources/
	cp -r Resources/Assets.xcassets build/Release/VoiceGum.app/Contents/Resources/
	cp Resources/Info.plist build/Release/VoiceGum.app/Contents/Info.plist
	@if [ -z "$(DEVELOPER_ID)" ]; then \
		echo "Warning: Developer ID not found. Code signing skipped."; \
	else \
		codesign --force --sign "$(DEVELOPER_ID)" --options runtime build/Release/VoiceGum.app; \
	fi

clean:
	rm -rf .build build

pkg:
	mkdir -p build/Release/VoiceGum.app/Contents/MacOS
	mkdir -p build/Release/VoiceGum.app/Contents/Resources
	cp $(BUILD_PATH)/VoiceGum build/Release/VoiceGum.app/Contents/MacOS/
	cp -r $(BUILD_PATH)/VoiceGum_VoiceGum.bundle build/Release/VoiceGum.app/Contents/Resources/
	cp -r Resources/Assets.xcassets build/Release/VoiceGum.app/Contents/Resources/
	cp Resources/Info.plist build/Release/VoiceGum.app/Contents/Info.plist
