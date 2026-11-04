.PHONY: build check mutate test run install verify verify-desktop verify-status package-release

# Desktop tests to run, as a swift test filter: make verify-desktop FILTER='DesktopE2ETests/(testA|testB)$'
FILTER ?= DesktopE2ETests

build:
	swift build

# Isolated loop: pure and simulated tests only. Safe while Defi runs: under DEFI_ISOLATED=1 any
# real macOS resource (Accessibility, event taps, hotkeys, displays, panels, session paths) traps.
check:
	swift build --build-tests
	./script/check.sh

# Plants known bugs one at a time and reports which ones make check misses.
mutate:
	./script/mutate.sh

# Desktop tests skip themselves unless DEFI_E2E=1; this never touches the desktop.
test:
	swift test

run:
	./script/build_and_run.sh

# Build, sign, install to ~/Applications, and check the installed daemon starts.
install:
	./script/build_and_run.sh --verify

# Build, Swift tests and workflow checks, recorded under dist/verification; never touches the desktop.
# The isolated loop runs first so a broken invariant fails fast.
verify: check
	./script/verify.sh local

# verify, then wait for the desktop reservation, install the signed build and run the desktop tests.
verify-desktop:
	./script/verify.sh full --filter '$(value FILTER)'

verify-status:
	./script/verify.sh status

package-release:
	./script/package_release.sh
