#!/bin/bash
#
# build-release.sh
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# Builds a release: the app, signed with the release identity, packed in a
# signed .dmg with the burn-line background. See docs/releasing.md.
#
#   macos/scripts/build-release.sh [--nightly] [--version 0.1.0] [--build 7] [--keychain path]
#
# The version and build number default to the app target's. The identity is
# "Burnline Release", or BURNLINE_SIGNING_IDENTITY; make it once with
# make-signing-identity.sh. Everything is written to build/release/, and the
# last line printed is the .dmg's path.

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
scripts="$root/macos/scripts"
out="$root/build/release"
identity="${BURNLINE_SIGNING_IDENTITY:-Burnline Release}"
# dmgbuild runs from a private environment, pinned, never the system's Python packages.
dmgbuild_version="1.6.7"

channel=stable version="" build="" keychain=""
while [ $# -gt 0 ]; do
    case "$1" in
        --nightly) channel=nightly ;;
        --version) version="$2"; shift ;;
        --build) build="$2"; shift ;;
        --keychain) keychain="$2"; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

if ! security find-identity -p codesigning ${keychain:+"$keychain"} | grep -q "\"$identity\""; then
    echo "No signing identity \"$identity\". Make it once with macos/scripts/make-signing-identity.sh." >&2
    exit 1
fi

rm -rf "$out/Burnline.app" "$out/stage"
mkdir -p "$out/stage"

# Stripped, as an Xcode archive is: debug symbols more than double the
# executable, and a release has no use for them.
settings=(BURNLINE_CHANNEL="$channel" DEPLOYMENT_POSTPROCESSING=YES)
[ -n "$version" ] && settings+=(MARKETING_VERSION="$version")
[ -n "$build" ] && settings+=(CURRENT_PROJECT_VERSION="$build")

echo "Building the $channel app…"
xcodebuild -project "$root/macos/Burnline.xcodeproj" -scheme Burnline -configuration Release \
    -derivedDataPath "$out/DerivedData" "${settings[@]}" build > "$out/xcodebuild.log" 2>&1 \
    || { tail -n 30 "$out/xcodebuild.log" >&2; exit 1; }
ditto "$out/DerivedData/Build/Products/Release/Burnline.app" "$out/stage/Burnline.app"
app="$out/stage/Burnline.app"

# Built ad-hoc, as in development, then signed here: an identity given to
# xcodebuild reaches the packages' resource bundles too, which then demand a
# development team. Inside out, so each bundle seals signed contents, keeping
# what each piece was given, such as Sparkle's helpers' entitlements.
echo "Signing with \"$identity\"…"
sign=(codesign --force --sign "$identity" ${keychain:+--keychain "$keychain"})
find "$app/Contents" -depth \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "*.dylib" \
    -o -path "*/Sparkle.framework/Versions/B/Autoupdate" \) -print0 |
    while IFS= read -r -d '' item; do
        "${sign[@]}" --preserve-metadata=identifier,entitlements,flags "$item" 2> /dev/null
    done
"${sign[@]}" --preserve-metadata=entitlements "$app" 2> /dev/null

# Every nested piece must verify, and the signature must name the release
# certificate: an ad-hoc one would change with every build.
codesign --verify --deep --strict "$app"
codesign --display --requirements - "$app" 2>&1 | grep -q 'certificate leaf' \
    || { echo "The app is not signed with a certificate." >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
echo "Drawing the background…"
background="$out/stage/background"
night=()
[ "$channel" = nightly ] && night=(--nightly)
swift "$scripts/dmg/background.swift" "$background.png" 1 ${night[@]+"${night[@]}"}
swift "$scripts/dmg/background.swift" "$background@2x.png" 2 ${night[@]+"${night[@]}"}
tiffutil -cathidpicheck "$background.png" "$background@2x.png" -out "$background.tiff" > /dev/null

if [ ! -x "$out/venv/bin/dmgbuild" ]; then
    python3 -m venv "$out/venv"
    "$out/venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==$dmgbuild_version"
fi

name="Burnline-$version"
[ "$channel" = nightly ] && volume="Burnline Nightly" || volume="Burnline"
dmg="$out/$name.dmg"
rm -f "$dmg"
echo "Packing $name.dmg…"
"$out/venv/bin/dmgbuild" -s "$scripts/dmg/settings.py" -D app="$app" -D background="$background.tiff" \
    "$volume" "$dmg" > /dev/null
codesign --sign "$identity" ${keychain:+--keychain "$keychain"} "$dmg"
codesign --verify "$dmg"

# The app as it will be installed, from the image: packing must not have
# touched it, or macOS may call the installed app damaged.
mount=$(mktemp -d)
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
verified=0
codesign --verify --deep --strict "$mount/Burnline.app" && verified=1
hdiutil detach -quiet "$mount"
[ "$verified" = 1 ] || { echo "The app inside $name.dmg does not verify." >&2; exit 1; }

echo "$dmg"
