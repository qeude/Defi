.PHONY: build test run verify package-release

build:
	swift build

test:
	swift test

run:
	./script/build_and_run.sh

verify:
	./script/build_and_run.sh --verify

package-release:
	./script/package_release.sh
