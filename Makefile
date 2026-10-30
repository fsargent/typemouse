.PHONY: build test app cert icon run restart dump windows clean

# Use full Xcode when installed (unit tests need XCTest). Otherwise use the Command Line Tools.
ifneq ($(wildcard /Applications/Xcode.app),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif
APP := $(HOME)/Applications/TypeMouse.app
OUT := $(HOME)/scratch/typemouse

build:
	swift build

test:
	swift test

cert:
	scripts/make-cert.sh

# Redraws Resources/AppIcon.icns and docs/images/icon.png.
icon:
	swift scripts/make-icon.swift

app:
	scripts/build-app.sh

run: app
	open "$(APP)"

restart: app
	-pkill -x TypeMouse
	sleep 0.5
	open "$(APP)"

# Diagnostics run inside the app bundle, so they use the app's Accessibility grant.
# Example: make dump APPNAME=Slack
dump:
	mkdir -p "$(OUT)"
	open -n -W "$(APP)" --args --dump $(if $(APPNAME),--app "$(APPNAME)") --out "$(OUT)/dump.txt"
	cat "$(OUT)/dump.txt"

windows:
	mkdir -p "$(OUT)"
	open -n -W "$(APP)" --args --windows --out "$(OUT)/windows.txt"
	cat "$(OUT)/windows.txt"

clean:
	swift package clean
