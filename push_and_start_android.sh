#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb not found in PATH" >&2
  exit 1
fi

DEVICE_BASE="/tmp"
TERM_VALUE="xterm-256color"
NO_RUN=0
SERIAL=""

usage() {
  cat <<EOF
Usage: $0 [--serial <id>] [--device-base <dir>] [--term <term>] [--no-run]

Pushes:
  - build_android/cmatrix -> <device-base>/cmatrix
  - terminfo via push_terminfo_android.sh -> <device-base>/terminfo/android_terminfo
  - cmatrix_start.sh -> <device-base>/cmatrix_start.sh

Then (unless --no-run) runs:
  adb shell -t <device-base>/cmatrix_start.sh --term <term>
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --serial)
      SERIAL="$2"
      shift 2
      ;;
    --device-base)
      DEVICE_BASE="$2"
      shift 2
      ;;
    --term)
      TERM_VALUE="$2"
      shift 2
      ;;
    --no-run)
      NO_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

ADB=(adb)
if [ -n "$SERIAL" ]; then
  ADB=(adb -s "$SERIAL")
fi

BIN_SRC="$ROOT_DIR/build_android/cmatrix"
if [ ! -f "$BIN_SRC" ]; then
  echo "Missing binary: $BIN_SRC" >&2
  echo "Build it first: ./build_android.sh" >&2
  exit 1
fi

echo "[1/3] Pushing terminfo..."
TERMINFO_DEVICE_DIR="$DEVICE_BASE/terminfo" "$ROOT_DIR/push_terminfo_android.sh"

echo "[2/3] Pushing cmatrix + launcher..."
"${ADB[@]}" push "$BIN_SRC" "$DEVICE_BASE/cmatrix" >/dev/null
"${ADB[@]}" push "$ROOT_DIR/cmatrix_start.sh" "$DEVICE_BASE/cmatrix_start.sh" >/dev/null

"${ADB[@]}" shell "chmod 755 '$DEVICE_BASE/cmatrix' '$DEVICE_BASE/cmatrix_start.sh'" >/dev/null

echo "[3/3] Done."

if [ "$NO_RUN" = "1" ]; then
  cat <<EOF
Pushed to device:
  $DEVICE_BASE/cmatrix
  $DEVICE_BASE/cmatrix_start.sh
  $DEVICE_BASE/terminfo/android_terminfo

Manual run (interactive tty preferred):
  adb shell -t
  $DEVICE_BASE/cmatrix_start.sh --term $TERM_VALUE
EOF
  exit 0
fi

RUN_ARGS=("$DEVICE_BASE/cmatrix_start.sh" --term "$TERM_VALUE")

echo "Running: adb shell -t ${RUN_ARGS[*]}"
set +e
"${ADB[@]}" shell -t "${RUN_ARGS[@]}"
RC=$?
set -e

if [ $RC -ne 0 ]; then
  cat <<EOF >&2
Run failed (exit=$RC).
If your adb doesn't allocate a PTY, try:
  adb shell
  $DEVICE_BASE/cmatrix_start.sh --term $TERM_VALUE
EOF
  exit $RC
fi
