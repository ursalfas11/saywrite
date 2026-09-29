APP_NAME   := Saywrite
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
export DEVELOPER_DIR ?= $(shell [ -d /Applications/Xcode.app ] && echo /Applications/Xcode.app/Contents/Developer || xcode-select -p)

.PHONY: build app install test run clean eval

build:
	swift build -c release --product $(APP_NAME)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(APP)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(APP)/Contents/Info.plist
	[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns $(APP)/Contents/Resources/ || true
	@# Ad-hoc signature with a designated requirement on the bundle identifier only, so macOS keeps
	@# the Accessibility permission across rebuilds (the default ad-hoc requirement is the cdhash).
	codesign --force --sign - --identifier dev.saywrite.app \
		-r='designated => identifier "dev.saywrite.app"' $(APP)
	@echo "Built $(APP)"

install: app
	-osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

run: app
	open $(APP)

test:
	swift test

eval:
	swift run -c release SaywriteEval Tests/Eval/cases.json

clean:
	rm -rf .build $(BUILD_DIR)
