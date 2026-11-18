CONFIG ?= release
SIGN_IDENTITY ?= -
APP := .build/AI Usage.app

.PHONY: app run test
app:
	swift build -c $(CONFIG)
	@set -eu; bin="$$(swift build -c $(CONFIG) --show-bin-path)"; \
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Helpers"; \
	install -m 644 Packaging/Info.plist "$(APP)/Contents/Info.plist"; \
	install -m 755 "$$bin/AIUsage" "$(APP)/Contents/MacOS/AIUsage"; \
	install -m 755 "$$bin/claude-quota-capture" "$(APP)/Contents/Helpers/claude-quota-capture"; \
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(APP)/Contents/Helpers/claude-quota-capture"; \
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(APP)"

run: app
	open "$(APP)"

test:
	@set -eu; dev="$${DEVELOPER_DIR:-$$(xcode-select -p)}"; \
	frameworks="$$dev/Library/Developer/Frameworks"; \
	if test -d "$$frameworks/Testing.framework"; then \
	  swift test --disable-xctest \
	    -Xswiftc -load-plugin-library -Xswiftc "$$dev/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
	    -Xswiftc -F -Xswiftc "$$frameworks" -Xlinker -F -Xlinker "$$frameworks" -Xlinker -rpath -Xlinker "$$frameworks"; \
	else swift test --disable-xctest; fi
