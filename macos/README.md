# Tokrate for macOS

Native SwiftUI menu-bar client for macOS 14+. App sources and UI tests live here; metric parsing, sharing and their tests live in `../shared/`.

Run from the repository root:

```sh
swift test --build-system native -j 2
./macos/script/build_and_run.sh
./macos/script/package_app.sh release
```

Bundles and release archives are staged in `macos/dist/`. See the [root README](../README.md) for privacy, signing and notarization instructions.
