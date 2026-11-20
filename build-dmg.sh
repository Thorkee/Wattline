#!/bin/bash
set -euo pipefail

# Run build-app.sh first, or supply a prebuilt signed bundle in WATTLINE_APP.
# Only maintainers building the installer need Xcode and Python 3.11 or later.
cd "$(dirname "$0")"
scratch=${SWIFTPM_BUILD_DIR:-.build}
app=${WATTLINE_APP:-"$scratch/Wattline.app"}
if [[ ! -d "$app" ]]; then
    echo "Missing $app. Run ./build-app.sh first or set WATTLINE_APP." >&2
    exit 1
fi
app=$(cd "$app" && pwd -P)
info="$app/Contents/Info.plist"
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info")
if [[ $(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info") != local.wattline.macos || ! $version =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Expected a Wattline release bundle." >&2
    exit 1
fi
codesign --verify --strict --all-architectures "$app"
xcrun lipo "$app/Contents/MacOS/Wattline" -verify_arch arm64 x86_64

if (( $# > 1 )); then
    echo "Usage: ./build-dmg.sh [output.dmg]" >&2
    exit 1
fi
output=${1:-"$scratch/Wattline-$version.dmg"}
if [[ "$output" != *.dmg || -d "$output" ]]; then
    echo "Expected a .dmg output file." >&2
    exit 1
fi
mkdir -p "$(dirname "$output")"
out_dir=$(cd "$(dirname "$output")" && pwd -P)
output="$out_dir/$(basename "$output")"
stage=$(mktemp -d "$out_dir/wattline-dmg.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT

python=${PYTHON3:-python3}
if ! "$python" -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
    echo 'Packaging requires Python 3.11 or later. Set PYTHON3 to its executable.' >&2
    exit 1
fi
"$python" -m venv "$stage/tools"
"$stage/tools/bin/python" -m pip --disable-pip-version-check install --quiet \
    --only-binary=:all: --require-hashes -r /dev/stdin <<'PACKAGES'
dmgbuild==1.6.7 --hash=sha256:37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf
ds_store==1.3.4 --hash=sha256:6d8ae662921846c96b03c244a92aab19a5b4fb3d9cada118fc83cace9250f049
mac_alias==2.2.4 --hash=sha256:c20f95f75d7f966dd8ea2f84c317d4ff4abee0db9cc8a13b454891c15aa04226
PACKAGES

xcrun swift Resources/DrawInstaller.swift "$stage/Installer.tiff"
"$stage/tools/bin/python" -m dmgbuild --no-hidpi -s Resources/dmg-settings.py \
    -D "app=$app" -D "background=$stage/Installer.tiff" -D "license=$PWD/LICENSE" \
    Wattline "$stage/Wattline.dmg"
hdiutil verify -quiet "$stage/Wattline.dmg"
mv -f "$stage/Wattline.dmg" "$output"
printf '%s\n' "$output"
