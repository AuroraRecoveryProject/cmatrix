#!/system/bin/sh
set -eu

# Device-side launcher for cmatrix.
# Assumes layout:
#   <DIR>/cmatrix
#   <DIR>/terminfo/android_terminfo/...

SELF="$0"
DIR="$(cd "$(dirname "$SELF")" && pwd)"

BIN="${CMATRIX_BIN:-$DIR/cmatrix}"
TERMINFO_DIR="${CMATRIX_TERMINFO:-$DIR/terminfo/android_terminfo}"

# Fallback if user copied android_terminfo directly.
if [ ! -d "$TERMINFO_DIR" ] && [ -d "$DIR/android_terminfo" ]; then
  TERMINFO_DIR="$DIR/android_terminfo"
fi

# Parse a couple of simple flags (optional):
#   --term <TERM>  -> override TERM
TERM_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --term)
      if [ $# -lt 2 ]; then
        echo "--term requires an argument" >&2
        exit 2
      fi
      TERM_OVERRIDE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$TERM_OVERRIDE" ]; then
  export TERM="$TERM_OVERRIDE"
else
  export TERM="${CMATRIX_TERM:-${TERM:-xterm-256color}}"
fi

export TERMINFO="$TERMINFO_DIR"
export TERMINFO_DIRS="$TERMINFO_DIR"

terminfo_entry_exists() {
  local name="$1"
  local first hex
  first="${name%${name#?}}" # first char
  # POSIX sh: get ASCII code via printf %d on a quoted char is not portable.
  # Use a tiny busybox/toybox-compatible trick with printf and LC_CTYPE=C.
  hex=$(LC_CTYPE=C printf '%02x' "'${first}")

  [ -f "$TERMINFO/$first/$name" ] || [ -f "$TERMINFO/$hex/$name" ]
}

if [ ! -d "$TERMINFO" ]; then
  echo "TERMINFO dir not found: $TERMINFO" >&2
  echo "Expected: $DIR/terminfo/android_terminfo (from push script)" >&2
  exit 1
fi

if ! terminfo_entry_exists "$TERM"; then
  if terminfo_entry_exists "xterm-256color"; then
    echo "TERM '$TERM' not found under TERMINFO; using TERM='xterm-256color'" >&2
    export TERM="xterm-256color"
  fi
fi

if ! terminfo_entry_exists "$TERM"; then
  echo "No usable terminfo entry found for TERM='$TERM' in: $TERMINFO" >&2
  echo "Try re-pushing terminfo or push the terminfo entry matching your real TERM." >&2
  exit 1
fi

exec "$BIN" "$@"
