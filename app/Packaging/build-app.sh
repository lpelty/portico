#!/usr/bin/env bash
# Release-build the app with a macOS SDK that compiles it, quietly.
#   app/Packaging/build-app.sh <repo>
#
# Tries the default SDK first. When that fails (a macOS beta's newest SDK can
# fail to compile SwiftUI: "@State" does not expand), retries with each other
# installed MacOSX*.sdk, newest first, via SDKROOT, and says which one worked.
# Compiler output is kept out of the way unless every attempt fails; then the
# last attempt's errors are shown.
#
# Environment:
#   PORTICO_SDKROOT         build with this SDK only (no fallback)
#   PORTICO_SDK_CANDIDATES  newline-separated SDK paths to fall back to, in order (default: the
#                           installed MacOSX*.sdk of the active developer dir, newest first)
#   PORTICO_SWIFT           the swift executable (default: swift); tests pass a stand-in
#
# On success prints the built products directory as the last line of stdout and records
# the SDK in <repo>/app/.build/portico-build.env (read by the doctor).
set -euo pipefail

repo="${1:?usage: build-app.sh <repo>}"
app="$repo/app"
swift="${PORTICO_SWIFT:-swift}"

say() { echo "$@" >&2; }

strip_ansi() { sed -e $'s/\x1b\\[[0-9;]*[A-Za-z]//g'; }

real_dir() { (cd -P "$1" 2>/dev/null && pwd); }

sdk_version() {
  local v
  v="$(plutil -extract Version raw -o - "$1/SDKSettings.plist" 2>/dev/null || true)"
  if [ -z "$v" ]; then
    v="$(basename "$1" .sdk)"
    v="${v#MacOSX}"
  fi
  echo "${v:-unknown}"
}

default_sdk() {
  if [ -n "${SDKROOT:-}" ]; then
    echo "$SDKROOT"
  else
    xcrun --sdk macosx --show-sdk-path 2>/dev/null || true
  fi
}

# The installed MacOSX*.sdk of the active developer dir, symlinks resolved, newest first.
installed_sdks() {
  local dev dir sdk real
  dev="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
  [ -n "$dev" ] || return 0
  for dir in "$dev/SDKs" "$dev/Platforms/MacOSX.platform/Developer/SDKs"; do
    [ -d "$dir" ] || continue
    for sdk in "$dir"/MacOSX*.sdk; do
      [ -d "$sdk" ] || continue
      real="$(real_dir "$sdk")" || continue
      printf '%s\t%s\n' "$(sdk_version "$real")" "$real"
    done
  done | sort -u | sort -t. -k1,1nr -k2,2nr -k3,3nr | cut -f2
}

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/portico-build.XXXXXX")"
trap 'rm -rf "$log_dir"' EXIT
last_log=""
attempt_no=0

# attempt <sdk|"">: one release build; "" inherits the environment's SDK (the default).
attempt() {
  attempt_no=$((attempt_no + 1))
  last_log="$log_dir/attempt-$attempt_no.log"
  if [ -n "$1" ]; then
    (cd "$app" && SDKROOT="$1" "$swift" build -c release) >"$last_log" 2>&1
  else
    (cd "$app" && "$swift" build -c release) >"$last_log" 2>&1
  fi
}

bin_path() {
  if [ -n "$1" ]; then
    (cd "$app" && SDKROOT="$1" "$swift" build -c release --show-bin-path 2>/dev/null) | tail -n 1
  else
    (cd "$app" && "$swift" build -c release --show-bin-path 2>/dev/null) | tail -n 1
  fi
}

record() { # <sdk path> <how chosen>
  mkdir -p "$app/.build"
  {
    echo "sdk=$1"
    echo "sdk_version=$(sdk_version "$1")"
    echo "chosen=$2"
  } >"$app/.build/portico-build.env"
}

show_errors() {
  local errors
  errors="$(strip_ansi <"$last_log" | grep -E '(^|[^a-z])error:' | sort -u | head -n 30 || true)"
  if [ -n "$errors" ]; then
    echo "$errors" >&2
  else
    strip_ansi <"$last_log" | tail -n 30 >&2
  fi
}

finish() { # <sdk passed to the build or ""> <sdk path to record> <how chosen>
  local products
  record "$2" "$3"
  products="$(bin_path "$1")"
  if [ -z "$products" ] || [ ! -d "$products" ]; then
    say "app: the build finished but swift did not name its products directory"
    exit 1
  fi
  echo "$products"
  exit 0
}

say "== app: swift build -c release"

if [ -n "${PORTICO_SDKROOT:-}" ]; then
  if [ ! -d "$PORTICO_SDKROOT" ]; then
    say "app: PORTICO_SDKROOT is $PORTICO_SDKROOT, which is not a directory"
    exit 1
  fi
  if attempt "$PORTICO_SDKROOT"; then
    say "== app: built with the macOS $(sdk_version "$PORTICO_SDKROOT") SDK ($PORTICO_SDKROOT, from PORTICO_SDKROOT)"
    finish "$PORTICO_SDKROOT" "$PORTICO_SDKROOT" "PORTICO_SDKROOT"
  fi
  say "app: the app does not build with the SDK in PORTICO_SDKROOT ($PORTICO_SDKROOT). The compiler said:"
  show_errors
  exit 1
fi

default="$(default_sdk)"
default_real="$(real_dir "$default" 2>/dev/null || true)"
default_label="the default macOS SDK"
[ -n "$default" ] && default_label="the default macOS $(sdk_version "$default") SDK ($default)"

if attempt ""; then
  say "== app: built with $default_label"
  finish "" "${default_real:-$default}" "default"
fi

if [ -n "${PORTICO_SDK_CANDIDATES:-}" ]; then
  candidates="$PORTICO_SDK_CANDIDATES"
else
  candidates="$(installed_sdks)"
fi

tried=("$default_label")
say "app: $default_label does not build the app; trying the other installed SDKs"
while IFS= read -r sdk; do
  [ -n "$sdk" ] || continue
  real="$(real_dir "$sdk" 2>/dev/null || echo "$sdk")"
  if [ -n "$default_real" ] && [ "$real" = "$default_real" ]; then
    continue
  fi
  label="the macOS $(sdk_version "$sdk") SDK ($sdk)"
  tried+=("$label")
  say "app: trying $label"
  if attempt "$sdk"; then
    say "== app: built with $label; $default_label does not build it"
    finish "$sdk" "$real" "fallback"
  fi
done <<<"$candidates"

say
say "app: the app did not build with any installed macOS SDK. Tried:"
for t in "${tried[@]}"; do say "  - $t"; done
say "app: update the Command Line Tools (softwareupdate, or: xcode-select --install), or set"
say "app: PORTICO_SDKROOT to an SDK that builds it. The last attempt's compiler errors:"
show_errors
exit 1
