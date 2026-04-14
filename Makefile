.PHONY: build app run clean kill release generate help

APP_NAME = Ainto
SCHEME = AintoApp
BUILD_DIR = AintoApp/build
APP_PATH = $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app
SPM_BINARY = AintoApp/.build/release/AintoApp
DMG_PATH = $(APP_NAME).dmg
APPLE_TEAM_ID = JQ43BAV5D8

build:
	@echo "Building Rust core..."
	@cd ainto-core && cargo build --release
	@echo "Building $(APP_NAME) (SPM)..."
	@cd AintoApp && swift build -c release

run: kill build
	@echo "Running $(APP_NAME)..."
	@$(SPM_BINARY) &

app: generate
	@echo "Building Rust core..."
	@cd ainto-core && cargo build --release
	@echo "Building $(APP_NAME).app (Xcode)..."
	@cd AintoApp && xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" || true
	@echo "Open with: open $(APP_PATH)"

generate:
	@echo "Generating Xcode project..."
	@cd AintoApp && xcodegen generate

kill:
	@pkill -x "$(APP_NAME)" 2>/dev/null || pkill -x "AintoApp" 2>/dev/null || true

clean:
	@echo "Cleaning..."
	@rm -rf $(BUILD_DIR) AintoApp/.build
	@echo "Done."

release: clean generate
	@echo "Building Rust core..."
	@cd ainto-core && cargo build --release
	@echo "Building $(APP_NAME) for release..."
	@cd AintoApp && xcodebuild \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY="Developer ID Application" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="$(APPLE_TEAM_ID)" \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
		OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
		build
	@echo "Notarizing..."
	@cd $(BUILD_DIR)/Build/Products/Release && \
		ditto -c -k --keepParent $(APP_NAME).app $(APP_NAME).zip && \
		xcrun notarytool submit $(APP_NAME).zip \
			--apple-id "$(APPLE_ID)" \
			--password "$(APPLE_PASSWORD)" \
			--team-id "$(APPLE_TEAM_ID)" \
			--wait && \
		xcrun stapler staple $(APP_NAME).app && \
		rm $(APP_NAME).zip
	@echo "Creating DMG..."
	@rm -f $(DMG_PATH)
	@if [ ! -d create-dmg ]; then git clone --depth 1 --branch v1.2.3 https://github.com/create-dmg/create-dmg.git; fi
	@./create-dmg/create-dmg \
		--volname "$(APP_NAME)" \
		--window-pos 200 120 \
		--window-size 500 320 \
		--icon-size 80 \
		--icon "$(APP_NAME).app" 125 175 \
		--app-drop-link 375 175 \
		--hide-extension "$(APP_NAME).app" \
		--no-internet-enable \
		$(DMG_PATH) \
		$(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app
	@echo "Done! Created $(DMG_PATH)"

help:
	@echo "Usage:"
	@echo "  make build    - Build Rust core + Swift app (SPM, fast)"
	@echo "  make run      - Kill, build, and run"
	@echo "  make app      - Build .app bundle (Xcode, for testing Sparkle/icon/login)"
	@echo "  make generate - Generate Xcode project from project.yml"
	@echo "  make kill     - Kill running instance"
	@echo "  make clean    - Remove build directories"
	@echo "  make release  - Build, notarize, and create DMG (CI use)"
