#!/bin/sh

set -eu

. "${CONFIG_DIR:-$HOME/.config/sketchybar}/plugins/defi_common.sh"
suffix=${NAME#defi.}
display=${suffix%%.*}
workspace=${suffix#*.}

"$DEFI_BIN" --monitor "$display" workspace "$workspace"
