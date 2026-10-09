APP_NAME   := Saywrite
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
export DEVELOPER_DIR ?= $(shell [ -d /Applications/Xcode.app ] && echo /Applications/Xcode.app/Contents/Developer || xcode-select -p)

.PHONY: build app install test run clean eval eval-rules

build:
	swift build -c release --product $(APP_NAME)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(APP)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(APP)/Contents/Info.plist
	[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns $(APP)/Contents/Resources/ || true
	cp -R Support/en.lproj Support/de.lproj $(APP)/Contents/Resources/
	@# Apache/BSD/MIT/CC BY require the notices to travel with binary redistributions.
	cp LICENSE THIRD_PARTY_LICENSES $(APP)/Contents/Resources/
	@# llama.cpp is a dynamic framework (the app's rpath points at Contents/Frameworks). Nested code is
	@# signed before the app itself.
	mkdir -p $(APP)/Contents/Frameworks
	@f="$$(swift build -c release --show-bin-path)/llama.framework"; \
	[ -d "$$f" ] || f="$$(find .build/artifacts -type d -path '*macos-arm64_x86_64/llama.framework' | head -1)"; \
	[ -d "$$f" ] || { echo "llama.framework not found"; exit 1; }; \
	ditto "$$f" $(APP)/Contents/Frameworks/llama.framework
	codesign --force --sign - $(APP)/Contents/Frameworks/llama.framework
	@# Ad-hoc signature with a designated requirement on the bundle identifier only, so macOS keeps
	@# the Accessibility permission across rebuilds (the default ad-hoc requirement is the cdhash).
	@# Trade-off: TCC trusts any binary that claims this identifier, so same-user code could sign itself
	@# as dev.saywrite.app and inherit the grants. Without a Developer ID certificate there is no stronger
	@# requirement that survives rebuilds; see "Signing" in the README.
	codesign --force --sign - --identifier dev.saywrite.app \
		-r='designated => identifier "dev.saywrite.app"' $(APP)
	@echo "Built $(APP)"

install: app
	-osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null
	@# The quit is asynchronous: wait for the old process (up to 10 s), then stop it, before replacing the bundle.
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.5; done; \
		pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

run: app
	open $(APP)

test:
	swift test

# AI eval: the built-in model if it is downloaded, otherwise Ollama (EVAL_ARGS="--backend ollama" to choose).
eval:
	swift run -c release SaywriteEval Tests/Eval/cases.json $(EVAL_ARGS)
	swift run -c release SaywriteEval Tests/Eval/cases-en.json $(EVAL_ARGS)

# Rules only, no LLM; fails when a set drops below Tests/Eval/rules-baseline.txt.
eval-rules:
	scripts/eval-rules.sh

clean:
	rm -rf .build $(BUILD_DIR)
