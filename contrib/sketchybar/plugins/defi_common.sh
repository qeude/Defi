#!/bin/sh

if [ -z "${DEFI_BIN:-}" ]; then
  if [ -x "$HOME/Applications/Defi.app/Contents/MacOS/defi" ]; then
    DEFI_BIN="$HOME/Applications/Defi.app/Contents/MacOS/defi"
  elif [ -x /Applications/Defi.app/Contents/MacOS/defi ]; then
    DEFI_BIN=/Applications/Defi.app/Contents/MacOS/defi
  else
    DEFI_BIN=$(command -v defi || true)
  fi
fi
[ -n "$DEFI_BIN" ] || exit 0
