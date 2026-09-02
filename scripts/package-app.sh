#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
output_root=${OUTPUT_DIR:-"$repo_root/dist"}
app_path="$output_root/G502XFnVoice.app"
identity=${CODE_SIGN_IDENTITY:-}

if [[ -z "$identity" ]]; then
    print -u2 "Set CODE_SIGN_IDENTITY to a signing identity allowed to use com.apple.developer.hid.virtual.device."
    exit 2
fi

if [[ -e "$app_path" ]]; then
    print -u2 "Refusing to overwrite existing app: $app_path"
    exit 3
fi

swift build --package-path "$repo_root" -c release --product G502XFnVoice
bin_path=$(swift build --package-path "$repo_root" -c release --show-bin-path)

mkdir -p "$app_path/Contents/MacOS"
cp "$repo_root/Packaging/G502XFnVoice-Info.plist" "$app_path/Contents/Info.plist"
cp "$bin_path/G502XFnVoice" "$app_path/Contents/MacOS/G502XFnVoice"

codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$repo_root/G502XFnVoice.entitlements" \
    --sign "$identity" \
    "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
print "Packaged: $app_path"
