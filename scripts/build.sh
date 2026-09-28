#!/usr/bin/env bash
set -euo pipefail

# Builds the unsigned dylib and owned TestHost app on macOS with Xcode installed.
# The sideload signer signs the injected app afterwards.

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir=${1:-"$repo_dir/dist"}

case "$dist_dir" in
    /*) ;;
    *) dist_dir="$PWD/$dist_dir" ;;
esac

artifact_dir="$dist_dir/SandboxArk"
log_file="$dist_dir/SandboxArk-build.log"

# Terminal colors
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    green=$(printf '\033[32m')
    red=$(printf '\033[31m')
    reset=$(printf '\033[0m')
else
    green=''
    red=''
    reset=''
fi

info() {
    printf '==> %s\n' "$*"
}

success() {
    printf '%s✓ %s%s\n' "$green" "$*" "$reset"
}

error() {
    printf '%s✗ %s%s\n' "$red" "$*" "$reset" >&2
}

mkdir -p "$dist_dir"

if [ -e "$artifact_dir" ]; then
    error "Refusing to overwrite existing artifacts in $artifact_dir"
    exit 1
fi

tmp_dir=$(mktemp -d "$dist_dir/.sandboxark-build.XXXXXX")

trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 1' HUP INT TERM

derived_data="$tmp_dir/DerivedData"
products="$derived_data/Build/Products/Release-iphoneos"

# Build
build_xcode() {
    NSUnbufferedIO=YES xcodebuild \
        -project "$repo_dir/SandboxArk.xcodeproj" \
        -scheme SandboxArk \
        -configuration Release \
        -sdk iphoneos \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=NO
}

info "Building SandboxArk (Release, iphoneos)"

if command -v xcbeautify >/dev/null 2>&1; then
    info "Using xcbeautify"

    if build_xcode 2>&1 | tee "$log_file" | xcbeautify; then
        success "Build succeeded"
    else
        error "Build failed"
        printf 'Full build log: %s\n' "$log_file" >&2
        exit 1
    fi
else
    info "xcbeautify not found; using raw xcodebuild output"

    if build_xcode 2>&1 | tee "$log_file"; then
        success "Build succeeded"
    else
        error "Build failed"
        printf 'Full build log: %s\n' "$log_file" >&2
        exit 1
    fi
fi

# Verify products
if [ ! -f "$products/sandboxark.dylib" ] ||
   [ ! -d "$products/SandboxArkTestHost.app" ]; then
    error "Xcode did not produce the expected dylib and TestHost app"
    exit 1
fi

# Embed build metadata
info "Generating build metadata"

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
    printf 'target.swiftLanguageVersion=6.0\n'
    printf 'target.dylibInstallName=@rpath/sandboxark.dylib\n'
} > "$app_bundle/build-metadata.txt"

# Package artifacts
info "Packaging unsigned artifacts"

mkdir -p "$tmp_dir/Payload" "$tmp_dir/artifacts"

ditto "$app_bundle" "$tmp_dir/Payload/SandboxArkTestHost.app"

ditto -c -k --sequesterRsrc --keepParent \
    "$tmp_dir/Payload" \
    "$tmp_dir/artifacts/SandboxArkTestHost.ipa"

cp "$products/sandboxark.dylib" \
    "$tmp_dir/artifacts/sandboxark.dylib"

mv "$tmp_dir/artifacts" "$artifact_dir"

success "Artifacts written to $artifact_dir"
printf 'Build log: %s\n' "$log_file"
