#!/bin/bash
set -euo pipefail

TERMINFO_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb not found in PATH"
  exit 1
fi

if ! command -v tic >/dev/null 2>&1; then
  echo "tic not found on host"
  exit 1
fi

TERMINFO_SRC="$TERMINFO_SRC_DIR/ncurses-6.4/misc/terminfo.src"
if [ ! -f "$TERMINFO_SRC" ]; then
  echo "terminfo source not found: $TERMINFO_SRC"
  exit 1
fi

OUT_DIR="$TERMINFO_SRC_DIR/android_terminfo"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

install_compiled_entry() {
  local name="$1"
  local src_file="$2"

  local first
  first="${name:0:1}"

  # Keep only the traditional first-character subdir layout (e.g. x/xterm-256color).
  mkdir -p "$OUT_DIR/$first"
  cp -f "$src_file" "$OUT_DIR/$first/$name"
}

copy_one() {
  local name="$1"
  local first
  local hex
  first="${name:0:1}"
  hex=$(printf '%02x' "'${first}")

  if [ -f "/usr/share/terminfo/$first/$name" ]; then
    install_compiled_entry "$name" "/usr/share/terminfo/$first/$name"
    return 0
  fi
  if [ -f "/usr/share/terminfo/$hex/$name" ]; then
    install_compiled_entry "$name" "/usr/share/terminfo/$hex/$name"
    return 0
  fi
  return 1
}

# Prefer copying the host's compiled terminfo entries (portable and avoids
# macOS /usr/bin/tic failing to write some entries like xterm-256color).
for entry in xterm-256color; do
  if ! copy_one "$entry"; then
    echo "Host terminfo missing $entry; trying tic..."
    /usr/bin/tic -x -o "$OUT_DIR" -e "$entry" "$TERMINFO_SRC"
  fi
done

DEVICE_DIR="${TERMINFO_DEVICE_DIR:-/tmp/terminfo}"
adb shell "rm -rf '$DEVICE_DIR' && mkdir -p '$DEVICE_DIR'"
adb push "$OUT_DIR" "$DEVICE_DIR" >/dev/null

echo "Pushed terminfo to $DEVICE_DIR/android_terminfo"

cat <<EOF

Run cmatrix like this:
  adb push build_android/cmatrix /tmp/cmatrix
  adb shell -t
  chmod 755 /tmp/cmatrix
  export TERMINFO=$DEVICE_DIR/android_terminfo
  export TERMINFO_DIRS=\$TERMINFO
  export TERM=xterm-256color
  /tmp/cmatrix

If it still fails and your actual TERM is different, push a matching terminfo entry
(extend this script's entry list) and re-run.
EOF
