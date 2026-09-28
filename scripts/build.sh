#!/bin/sh
set -eu

# Builds the unsigned dylib and owned TestHost app on macOS with Xcode installed.
# The sideload signer signs the injected app afterwards.

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir=${1:-"$repo_dir/dist"}
case "$dist_dir" in
    /*) ;;
    *) dist_dir="$PWD/$dist_dir" ;;
esac
artifact_dir="$dist_dir/SandboxArk"

mkdir -p "$dist_dir"
if [ -e "$artifact_dir" ]; then
    echo "Refusing to overwrite existing artifacts in $artifact_dir" >&2
    exit 1
fi

tmp_dir=$(mktemp -d "$dist_dir/.sandboxark-build.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 1' HUP INT TERM
derived_data="$tmp_dir/DerivedData"
products="$derived_data/Build/Products/Release-iphoneos"

xcodebuild -project "$repo_dir/SandboxArk.xcodeproj" \
    -scheme SandboxArk -configuration Release -sdk iphoneos \
    -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO

if [ ! -f "$products/sandboxark.dylib" ] || [ ! -d "$products/SandboxArkTestHost.app" ]; then
    echo "Xcode did not produce the expected dylib and TestHost app" >&2
    exit 1
fi

app_bundle="$products/SandboxArkTestHost.app"
{
    printf 'build.capturedAtUTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'builder.macOSVersion=%s\n' "$(sw_vers -productVersion)"
    printf 'builder.macOSBuild=%s\n' "$(sw_vers -buildVersion)"
    printf 'builder.architecture=%s\n' "$(uname -m)"
    printf 'toolchain.xcode=%s\n' "$(xcodebuild -version | tr '\n' ' ')"
    printf 'toolchain.iOSSDK=%s\n' "$(xcrun --sdk iphoneos --show-sdk-version)"
    printf 'toolchain.swift=%s\n' "$(xcrun swiftc --version | tr '\n' ' ')"
    printf 'toolchain.clang=%s\n' "$(xcrun --sdk iphoneos clang --version | sed '/^[[:space:]]*InstalledDir:/d' | tr '\n' ' ')"
    printf 'build.configuration=Release\n'
    printf 'build.signing=disabled; the sideload signer signs the injected app\n'
    printf 'target.architectures=arm64\n'
    printf 'target.minimumIOS=16.0\n'
    printf 'target.swiftLanguageVersion=5.0\n'
    printf 'target.dylibInstallName=@rpath/sandboxark.dylib\n'
} > "$app_bundle/build-metadata.txt"

mkdir -p "$tmp_dir/Payload" "$tmp_dir/artifacts"
ditto "$app_bundle" "$tmp_dir/Payload/SandboxArkTestHost.app"
ditto -c -k --sequesterRsrc --keepParent "$tmp_dir/Payload" \
    "$tmp_dir/artifacts/SandboxArkTestHost.ipa"
cp "$products/sandboxark.dylib" "$tmp_dir/artifacts/sandboxark.dylib"
mv "$tmp_dir/artifacts" "$artifact_dir"

printf 'Unsigned artifacts written to %s\n' "$artifact_dir"
