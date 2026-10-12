SCHEME = NotchApp

.PHONY: gen build run clean test

gen:
	xcodegen generate

build: gen
	xcodebuild -quiet -scheme $(SCHEME) -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build build

test: gen
	xcodebuild -quiet -scheme $(SCHEME) -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test

run: build
	open build/Build/Products/Debug/$(SCHEME).app

clean:
	rm -rf build $(SCHEME).xcodeproj
