#!/bin/bash
set -euo pipefail

# Local builds use ad-hoc signing. For a release, set WATTLINE_DEVELOPER_ID to
# the exact name or SHA-1 fingerprint from security find-identity -v -p codesigning.
signing_id=-
signing_options=(--timestamp=none)
if [[ ${WATTLINE_DEVELOPER_ID+x} ]]; then
    if ! signing_id=$(security find-identity -v -p codesigning | awk '
        /"Developer ID Application: / {
            name = $0
            sub(/^[^"]*"/, "", name)
            sub(/"$/, "", name)
            wanted = ENVIRON["WATTLINE_DEVELOPER_ID"]
            if (wanted == name || toupper(wanted) == toupper($2)) ids[$2] = 1
        }
        END {
            for (id in ids) { count++; selected = id }
            if (count != 1) exit 1
            print selected
        }'); then
        echo 'WATTLINE_DEVELOPER_ID must match one valid Developer ID Application identity. Use its SHA-1 fingerprint if the name is ambiguous.' >&2
        exit 1
    fi
    signing_options=(--options runtime --timestamp)
fi

cd "$(dirname "$0")"
scratch=${SWIFTPM_BUILD_DIR:-.build}
mkdir -p "$scratch"
scratch=$(cd "$scratch" && pwd -P)
stage=$(mktemp -d "$scratch/wattline-package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT

bundle="$stage/Wattline.app"
app="$scratch/Wattline.app"
executable="$bundle/Contents/MacOS/Wattline"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$stage/Wattline.iconset"
install -m 644 Resources/Info.plist "$bundle/Contents/Info.plist"
minimum=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - Resources/Info.plist)
sdk=$(xcrun --sdk macosx --show-sdk-path)

architectures=(arm64 x86_64)
slices=()
for arch in "${architectures[@]}"; do
    build=(xcrun swift build --configuration release --scratch-path "$scratch"
           --sdk "$sdk" --triple "$arch-apple-macosx$minimum")
    "${build[@]}" --product Wattline
    binary_dir=$("${build[@]}" --show-bin-path)
    install -m 755 "$binary_dir/Wattline" "$stage/Wattline-$arch"
    slices+=("$stage/Wattline-$arch")
done
xcrun lipo -create "${slices[@]}" -output "$executable"
xcrun lipo "$executable" -verify_arch "${architectures[@]}"
for arch in "${architectures[@]}"; do
    if ! xcrun vtool -arch "$arch" -show-build "$executable" |
        awk -v minimum="$minimum" '$1 == "platform" && $2 == "MACOS" { mac = 1 }
                                  $1 == "minos" && $2 == minimum { version = 1 }
                                  END { exit !(mac && version) }'; then
        echo "Unexpected macOS deployment target for $arch (expected $minimum)." >&2
        exit 1
    fi
done

xcrun swift Resources/DrawIcon.swift "$stage/Wattline.iconset"
iconutil -c icns "$stage/Wattline.iconset" -o "$bundle/Contents/Resources/Wattline.icns"
codesign --force --sign "$signing_id" "${signing_options[@]}" "$bundle"
codesign --verify --strict --all-architectures "$bundle"
if [[ $signing_id != - ]]; then
    # Apple's leaf-certificate extension identifies a Developer ID Application.
    codesign --verify --all-architectures -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$bundle"
    for arch in "${architectures[@]}"; do
        if ! LC_ALL=C codesign --display --verbose=4 --architecture "$arch" "$bundle" 2>&1 |
            awk '/^CodeDirectory .*flags=[^ ]*runtime/ { runtime = 1 }
                 /^Timestamp=.+/ { stamp = 1 }
                 END { exit !(runtime && stamp) }'; then
            echo "Missing hardened runtime or secure timestamp in $arch release signature." >&2
            exit 1
        fi
    done
fi

# Install the verified bundle with a single filesystem operation, including
# when another invocation has just published a completed bundle.
xcrun swift - "$bundle" "$app" <<'SWIFT'
import Darwin

let staged = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
if renamex_np(staged, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST,
          renamex_np(staged, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("Publishing Wattline.app")
        exit(1)
    }
}
SWIFT
printf '%s\n' "$app"
