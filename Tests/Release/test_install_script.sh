#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
FAKES="$TEST_DIR/bin"
RELEASE="$TEST_DIR/release"
TARGET="$TEST_DIR/apps"
mkdir -p "$FAKES" "$RELEASE/Defi.app" "$TARGET/Defi.app"
echo new > "$RELEASE/Defi.app/marker"
echo old > "$TARGET/Defi.app/marker"
(cd "$RELEASE" && ditto -c -k --keepParent Defi.app Defi-v9.9.9.zip && shasum -a 256 Defi-v9.9.9.zip > Defi-v9.9.9.zip.sha256)

# No network or real signature: exercise the script through fake CLI boundaries.
cat > "$FAKES/curl" <<FAKE
#!/bin/sh
case "\$*" in
  *-w*) printf 'https://github.com/qeude/Defi/releases/tag/v9.9.9' ;;
  *) while [ "\$1" != -o ]; do shift; done; cp "$RELEASE/\${3##*/}" "\$2" ;;
esac
FAKE
cat > "$FAKES/codesign" <<FAKE
#!/bin/sh
[ "\${CODESIGN_FAILS:-0}" = 0 ]
FAKE
printf '#!/bin/sh\necho "$1" > "%s/opened"\n' "$TEST_DIR" > "$FAKES/open"
printf '#!/bin/sh\necho arm64\n' > "$FAKES/uname"
chmod +x "$FAKES"/*

run() { PATH="$FAKES:$PATH" DEFI_INSTALL_DIR="$TARGET" "$ROOT/script/install.sh" >"$TEST_DIR/log" 2>&1; }
marker() { cat "$TARGET/Defi.app/marker"; }
leftovers() { find "$TARGET" -maxdepth 1 -name '.Defi-install.*' | wc -l | tr -d ' '; }

if CODESIGN_FAILS=1 run; then echo "accepted an invalid signature" >&2; exit 1; fi
[[ "$(marker)" == old && ! -e "$TEST_DIR/opened" && "$(leftovers)" == 0 ]]

printf '%064d  Defi-v9.9.9.zip\n' 1 > "$RELEASE/good.sha256"
mv "$RELEASE/Defi-v9.9.9.zip.sha256" "$RELEASE/saved.sha256"
mv "$RELEASE/good.sha256" "$RELEASE/Defi-v9.9.9.zip.sha256"
if run; then echo "accepted a wrong checksum" >&2; exit 1; fi
[[ "$(marker)" == old && "$(leftovers)" == 0 ]]
mv "$RELEASE/saved.sha256" "$RELEASE/Defi-v9.9.9.zip.sha256"

chmod a-w "$TARGET/Defi.app"
if run; then echo "accepted an unwritable app" >&2; exit 1; fi
chmod u+w "$TARGET/Defi.app"
grep -q 'cannot replace' "$TEST_DIR/log"
[[ "$(marker)" == old && ! -e "$TEST_DIR/opened" && "$(leftovers)" == 0 ]]

run
[[ "$(marker)" == new && "$(leftovers)" == 0 && "$(cat "$TEST_DIR/opened")" == "$TARGET/Defi.app" ]]

rm -rf "$TARGET/Defi.app"
run
[[ "$(marker)" == new ]]
echo "install script tests passed"
