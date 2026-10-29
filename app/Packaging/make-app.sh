#!/usr/bin/env bash
# Assemble <name>.app from a release build: Info.plist, the binary, its resource bundles,
# the icon, signed locally. Stock macOS tools only (plutil, sips, iconutil, codesign).
#
#   app/Packaging/make-app.sh --products DIR --dest DIR --name NAME --icon PNG \
#       --version X.Y.Z --gateway-bin PATH [--min-macos 15.0]
#
# The bundle is built in a temporary directory beside the destination and moved
# into place, replacing an existing <name>.app. Prints the installed path last.
set -euo pipefail

products="" dest="" name="" icon="" version="" gateway_bin="" min_macos="15.0"
while [ $# -gt 0 ]; do
  case "$1" in
    --products) products="$2"; shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --icon) icon="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --gateway-bin) gateway_bin="$2"; shift 2 ;;
    --min-macos) min_macos="$2"; shift 2 ;;
    *) echo "make-app: unknown argument $1" >&2; exit 2 ;;
  esac
done
for v in products dest name icon version gateway_bin; do
  if [ -z "${!v}" ]; then echo "make-app: --${v//_/-} is required" >&2; exit 2; fi
done

binary="$products/Portico"
if [ ! -x "$binary" ]; then
  echo "make-app: $binary is missing; the release build did not produce it" >&2
  exit 1
fi
if [ ! -f "$icon" ]; then
  echo "make-app: icon $icon is missing" >&2
  exit 1
fi

# A file name: no slashes or colons, no leading dot.
name="${name//\//-}"
name="${name//:/-}"
while [ "${name#.}" != "$name" ]; do name="${name#.}"; done
[ -n "$name" ] || name="Portico"
slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')"
[ -n "$slug" ] || slug="portico"
exe="$name"

mkdir -p "$dest"
dest="$(cd -P "$dest" && pwd)"
work="$(mktemp -d "$dest/.portico-app.XXXXXX")"
trap 'rm -rf "$work"' EXIT
bundle="$work/$name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

cp "$binary" "$bundle/Contents/MacOS/$exe"
chmod 755 "$bundle/Contents/MacOS/$exe"
# SwiftPM resource bundles: newer toolchains look in Contents/Resources (Bundle.main.resourceURL).
for res in "$products"/*.bundle; do
  [ -d "$res" ] || continue
  cp -R "$res" "$bundle/Contents/Resources/"
done

# The icon: every iconset size, @2x included, from one PNG.
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
read -r w h < <(sips -g pixelWidth -g pixelHeight "$icon" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w, h}')
if [ -z "${w:-}" ] || [ -z "${h:-}" ]; then
  echo "make-app: $icon is not an image sips can read" >&2
  exit 1
fi
if [ "$w" != 1024 ] || [ "$h" != 1024 ]; then
  echo "make-app: warning: $icon is ${w}x${h}; a 1024x1024 PNG is expected, it is scaled" >&2
fi
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png -z "$double" "$double" "$icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

plist="$bundle/Contents/Info.plist"
plutil -create xml1 "$plist"
set_string() { plutil -insert "$1" -string "$2" "$plist"; }
set_string CFBundleDevelopmentRegion en
set_string CFBundleInfoDictionaryVersion 6.0
set_string CFBundleName "$name"
set_string CFBundleDisplayName "$name"
set_string CFBundleIdentifier "dev.portico.$slug"
set_string CFBundleExecutable "$exe"
set_string CFBundleIconFile AppIcon
set_string CFBundlePackageType APPL
set_string CFBundleShortVersionString "$version"
set_string CFBundleVersion "$version"
set_string LSMinimumSystemVersion "$min_macos"
set_string NSPrincipalClass NSApplication
plutil -insert NSHighResolutionCapable -bool YES "$plist"
set_string PorticoGatewayBin "$gateway_bin"
plutil -lint "$plist" >/dev/null

codesign --force --deep -s - "$bundle" 2>"$work/codesign.log" || {
  cat "$work/codesign.log" >&2
  echo "make-app: codesign failed" >&2
  exit 1
}

target="$dest/$name.app"
if [ -e "$target" ]; then
  mv "$target" "$work/previous.app"
fi
if ! mv "$bundle" "$target"; then
  [ -e "$work/previous.app" ] && mv "$work/previous.app" "$target"
  echo "make-app: could not move the new app to $target" >&2
  exit 1
fi
echo "$target"
