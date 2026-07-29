.PHONY: build test run verify

build:
	swift build

test:
	swift test

run:
	./script/build_and_run.sh

verify:
	./script/build_and_run.sh --verify
