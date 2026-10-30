#!/bin/sh
# Installs the latest Defi release: curl -fsSL <this file's raw URL> | sh
# curl adds no quarantine attribute, so the signature below is the trust check.
# Set DEFI_INSTALL_DIR to choose the folder that receives Defi.app.
set -eu

# Same pin as defiReleaseRequirement in Sources/DefiMacOS/AppUpdater.swift.
REQUIREMENT='identifier "com.qeude.defi" and certificate leaf = H"b81a903423676253b0eff36c4cdfbe3351742b68"'
RELEASES='https://github.com/qeude/Defi/releases'

fail() {
  echo "defi install: $1" >&2
  exit 1
}

install_directory() {
  if [ -n "${DEFI_INSTALL_DIR:-}" ]; then
    echo "$DEFI_INSTALL_DIR"
  elif [ -d /Applications/Defi.app ]; then
    echo /Applications
  elif [ -d "$HOME/Applications/Defi.app" ] || [ ! -w /Applications ]; then
    echo "$HOME/Applications"
  else
    echo /Applications
  fi
}

# Everything runs from here, so a truncated download executes nothing.
main() {
  [ "$(uname -m)" = arm64 ] || fail "Defi requires an Apple Silicon Mac"
  latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES/latest")"
  tag="${latest##*/}"
  version="${tag#v}"
  case "$tag" in
    v[0-9]*) ;;
    *) fail "could not find the latest release" ;;
  esac

  directory="$(install_directory)"
  mkdir -p "$directory"
  target="$directory/Defi.app"
  # Same volume as the target, so replacing it is a rename.
  work="$(mktemp -d "$directory/.Defi-install.XXXXXX")"
  trap 'rm -rf "$work"' EXIT

  archive="Defi-v$version.zip"
  echo "Downloading Defi ${version}..."
  curl -fsSL -o "$work/$archive" "$RELEASES/download/$tag/$archive"
  curl -fsSL -o "$work/$archive.sha256" "$RELEASES/download/$tag/$archive.sha256"
  (cd "$work" && shasum -a 256 -c "$archive.sha256" >/dev/null) || fail "checksum mismatch"

  mkdir "$work/new" "$work/previous"
  ditto -x -k "$work/$archive" "$work/new"
  codesign --verify --deep --strict -R="$REQUIREMENT" "$work/new/Defi.app" 2>/dev/null \
    || fail "the download is not signed by Defi's release certificate"

  # Refuse before stopping Defi: a failure below would leave no window manager.
  [ ! -e "$target" ] || [ -w "$target" ] || fail "cannot replace $target"

  if pgrep -f "$target/Contents/MacOS/defi-daemon" >/dev/null; then
    echo "Stopping the running Defi..."
    "$target/Contents/MacOS/defi" quit >/dev/null 2>&1 || true
    attempts=0
    while pgrep -f "$target/Contents/MacOS/defi-daemon" >/dev/null; do
      attempts=$((attempts + 1))
      [ "$attempts" -le 150 ] || fail "Defi did not stop; nothing was changed"
      sleep 0.2
    done
  fi

  if [ -e "$target" ]; then
    mv "$target" "$work/previous/Defi.app" || {
      open "$target"
      fail "could not replace $target"
    }
    mv "$work/new/Defi.app" "$target" || {
      mv "$work/previous/Defi.app" "$target" || {
        trap - EXIT
        fail "could not restore Defi; your copy is at $work/previous/Defi.app"
      }
      open "$target"
      fail "could not replace $target"
    }
  else
    mv "$work/new/Defi.app" "$target"
  fi

  open "$target"
  echo "Defi $version is installed at $target and updates itself from now on."
}

main
