# SandboxArk

> [简体中文](README.zh-CN.md) | **English**

SandboxArk is an injectable iOS dynamic library that provides access to private data available to the host application and allows it to be exported as a backup archive.

SandboxArk supports non-jailbroken arm64 devices running iOS / iPadOS 16 or later. It can be installed using sideloading tools that support dylib injection, such as Feather.

## Prerequisites

* A macOS computer with Xcode and the iOS SDK installed for building the project.
* An IPA file of the target application.
* A signing certificate, provisioning profile, and a sideloading tool that supports dylib injection.

## Building

Run the build script:

```sh
sh scripts/build.sh
```

Build artifacts are generated in `dist/SandboxArk/`:

* `sandboxark.dylib`: The dynamic library to inject into the target application.
* `SandboxArkTestHost.ipa`: A test application included with the project.
* `build-metadata.txt`: Build environment information, including Xcode, iOS SDK, Swift, Clang, and target configuration details.

## Releases

Pushing a Git tag matching the `vMAJOR.MINOR.PATCH` format triggers a GitHub Actions workflow that builds the project on macOS and uploads `sandboxark.dylib` to the corresponding GitHub Release.

The release asset and build attestation can be verified using the GitHub CLI. Replace the version in the following commands with the desired release version:

```sh
gh release verify-asset v0.1.0 sandboxark.dylib --repo moraxyc/SandboxArk
gh attestation verify sandboxark.dylib --repo moraxyc/SandboxArk
```

## Injection and Installation

1. Import the target application's IPA into a compatible sideloading tool.
2. Add `sandboxark.dylib` to the application.
3. Sign the modified application and install it on the device.

## Opening the Interface

After launching the application, press and hold the screen with three fingers for approximately 1.5 seconds to open the SandboxArk interface.

