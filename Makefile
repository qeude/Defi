.PHONY: build test run install verify verify-desktop verify-status package-release

# Desktop tests to run, as a swift test filter: make verify-desktop FILTER='DesktopE2ETests/(testA|testB)$'
FILTER ?= DesktopE2ETests

build:
	swift build

# Desktop tests skip themselves unless DEFI_E2E=1; this never touches the desktop.
test:
	swift test

run:
	./script/build_and_run.sh

# Build, sign, install to ~/Applications, and check the installed daemon starts.
install:
	./script/build_and_run.sh --verify

# Build, Swift tests and workflow checks, recorded under dist/verification; never touches the desktop.
verify:
	./script/verify.sh local

# verify, then wait for the desktop reservation, install the signed build and run the desktop tests.
verify-desktop:
	./script/verify.sh full --filter '$(value FILTER)'

verify-status:
	./script/verify.sh status

package-release:
	./script/package_release.sh
