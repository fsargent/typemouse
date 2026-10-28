.PHONY: build test app cert run restart dump windows clean

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
APP := $(HOME)/Applications/TypeMouse.app
OUT := $(HOME)/scratch/typemouse

build:
	swift build

test:
	swift test

cert:
	scripts/make-cert.sh

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
