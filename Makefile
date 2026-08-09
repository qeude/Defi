.PHONY: build test run verify package-dmg

build:
	swift build

test:
	swift test

run:
	./script/build_and_run.sh

verify:
	./script/build_and_run.sh --verify

package-dmg:
	./script/package_dmg.sh
