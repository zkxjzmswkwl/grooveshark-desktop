# GrooveShark — SwiftPM release binary packaged as a macOS app bundle.

APP_NAME := GrooveShark
BUNDLE_NAME := $(APP_NAME).app
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(BUNDLE_NAME)
SHARE_DIR := $(DIST_DIR)/GrooveShark-share
ZIP := $(DIST_DIR)/GrooveShark-macOS.zip

ICON_SRC := grooveshark-icon.png
ICONSET := Packaging/AppIcon.iconset
PACKAGED_ICNS := Packaging/AppIcon.icns
RESOURCES_ICNS := $(APP_BUNDLE)/Contents/Resources/AppIcon.icns

UNAME_M := $(shell uname -m)
BUILD_ARCH := $(UNAME_M)
SWIFT_TRIPLE := $(if $(filter arm64,$(UNAME_M)),arm64-apple-macosx,x86_64-apple-macosx)
BUILD_RELEASE_DIR := .build/$(SWIFT_TRIPLE)/release
SPM_BINARY := $(BUILD_RELEASE_DIR)/mplayer
MACOS_EXE := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
INFO_PLIST := $(APP_BUNDLE)/Contents/Info.plist

SOURCES := $(shell find Sources -name '*.swift' 2>/dev/null)

.PHONY: all build icons app package clean codesign-adhoc zip distribute serve-lan open help

help:
	@echo "Targets:"
	@echo "  make build          — swift build -c release (native architecture)"
	@echo "  make icons          — rebuild Packaging/AppIcon.icns from $(ICON_SRC)"
	@echo "  make app            — build + assemble $(BUNDLE_NAME) under $(DIST_DIR)/"
	@echo "  make package        — synonym for app"
	@echo "  make codesign-adhoc — ad-hoc sign the bundle (local Gatekeeper / quarantine)"
	@echo "  make zip            — signed app + friend installer in $(ZIP)"
	@echo "  make distribute     — same as zip (for sharing)"
	@echo "  make serve-lan      — HTTP server on LAN; friend downloads the zip"
	@echo "  make open           — launch the bundled app (after app)"
	@echo "  make clean          — swift package clean and remove $(DIST_DIR)/ + icon build"

all: app

build: $(SPM_BINARY)

$(SPM_BINARY): Package.swift $(SOURCES)
	swift build -c release

# macOS bundle icon (.icns) via iconutil (requires square source artwork).
$(PACKAGED_ICNS): $(ICON_SRC)
	rm -rf "$(ICONSET)"
	mkdir -p "$(ICONSET)"
	sips -z 16 16 "$(ICON_SRC)" --out "$(ICONSET)/icon_16x16.png"
	sips -z 32 32 "$(ICON_SRC)" --out "$(ICONSET)/icon_16x16@2x.png"
	sips -z 32 32 "$(ICON_SRC)" --out "$(ICONSET)/icon_32x32.png"
	sips -z 64 64 "$(ICON_SRC)" --out "$(ICONSET)/icon_32x32@2x.png"
	sips -z 128 128 "$(ICON_SRC)" --out "$(ICONSET)/icon_128x128.png"
	sips -z 256 256 "$(ICON_SRC)" --out "$(ICONSET)/icon_128x128@2x.png"
	sips -z 256 256 "$(ICON_SRC)" --out "$(ICONSET)/icon_256x256.png"
	sips -z 512 512 "$(ICON_SRC)" --out "$(ICONSET)/icon_256x256@2x.png"
	sips -z 512 512 "$(ICON_SRC)" --out "$(ICONSET)/icon_512x512.png"
	sips -z 1024 1024 "$(ICON_SRC)" --out "$(ICONSET)/icon_512x512@2x.png"
	iconutil -c icns "$(ICONSET)" -o "$(PACKAGED_ICNS)"
	rm -rf "$(ICONSET)"

icons: $(PACKAGED_ICNS)

$(INFO_PLIST): Packaging/Info.plist
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	cp Packaging/Info.plist "$(INFO_PLIST)"

$(RESOURCES_ICNS): $(PACKAGED_ICNS)
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp "$(PACKAGED_ICNS)" "$(RESOURCES_ICNS)"

$(MACOS_EXE): $(SPM_BINARY) $(INFO_PLIST) $(RESOURCES_ICNS)
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	install -m 755 "$(SPM_BINARY)" "$(MACOS_EXE)"

app package: $(MACOS_EXE)
	@echo "Built $(APP_BUNDLE)"

codesign-adhoc: app
	codesign --force --deep --timestamp=none -s - "$(APP_BUNDLE)"
	@echo "Ad-hoc signed $(APP_BUNDLE)"

$(SHARE_DIR): codesign-adhoc Packaging/FRIEND_INSTALL.txt Packaging/Install-GrooveShark.command
	rm -rf "$(SHARE_DIR)"
	mkdir -p "$(SHARE_DIR)"
	ditto "$(APP_BUNDLE)" "$(SHARE_DIR)/$(BUNDLE_NAME)"
	cp Packaging/FRIEND_INSTALL.txt "$(SHARE_DIR)/"
	cp Packaging/Install-GrooveShark.command "$(SHARE_DIR)/Install-GrooveShark.command"
	chmod +x "$(SHARE_DIR)/Install-GrooveShark.command"
	echo "$(BUILD_ARCH)" > "$(SHARE_DIR)/BUILD_ARCH.txt"

zip distribute: $(ZIP)

$(ZIP): $(SHARE_DIR)
	rm -f "$(ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(SHARE_DIR)" "$(ZIP)"
	@echo "Created $(ZIP) ($(BUILD_ARCH)) — send or run: make serve-lan"

serve-lan: $(ZIP)
	@chmod +x Packaging/serve-lan.sh
	@./Packaging/serve-lan.sh

open: app
	open "$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf "$(DIST_DIR)"
	rm -f "$(PACKAGED_ICNS)"
	rm -rf "$(ICONSET)"
