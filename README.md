# ShakeDrop

A tiny free/open-source macOS menu-bar app: click the hand icon in the status
bar, drop a file into the popover, then **shake your mouse** to pop open the
AirDrop sharing sheet. No dock icon, no main window — it lives in the status
bar until you quit from the menu.

Built with SwiftUI + AppKit, no third-party dependencies. macOS 13+.

## Status bar

Icon: SF Symbol `hand.draw` (closed hand with extended index finger inside a
circle). Click to open the drop zone; the menu below the popover has
**About** and **Quit ShakeDrop** (⌘Q while the popover is open).

## Running an unsigned build on macOS

This repo is intended to be built and run locally, which means the binary
won't be signed with an Apple Developer ID. macOS Gatekeeper will refuse to
launch an unsigned app the first time with a dialog like
*"ShakeDrop.app cannot be opened because the developer cannot be verified"*.

There are two clean ways around it.

### Option 1 — Build with `xcodebuild` (recommended)

```sh
xcodebuild -project ShakeDrop.xcodeproj -scheme ShakeDrop \
           -configuration Debug build \
           CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

`CODE_SIGN_IDENTITY="-"` does an **ad-hoc** local sign, which is enough for
your own machine. The output is in Xcode's DerivedData — find it with:

```sh
DD=$(xcodebuild -project ShakeDrop.xcodeproj -scheme ShakeDrop \
              -showBuildSettings -configuration Debug 2>/dev/null \
              | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR /{print $2; exit}')
open "$DD/ShakeDrop.app"
```

### Option 2 — Run from Xcode

Open the project, select the `ShakeDrop` scheme, and press ⌘R. Xcode does
the ad-hoc sign for you.

### If macOS still blocks it

If you previously tried to open the unsigned bundle and macOS cached the
quarantine, do this once:

```sh
xattr -dr com.apple.quarantine /path/to/ShakeDrop.app
```

Or, in Finder: right-click the app → **Open** → **Open** in the dialog.
That's a one-time approval per machine.

## Building

Requirements: Xcode 15+ on macOS 13+.

```sh
xcodebuild -project ShakeDrop.xcodeproj -scheme ShakeDrop \
           -configuration Debug build
```

## Releasing

Push a version tag (`vX.Y.Z`) to trigger the GitHub Actions release
workflow (see `.github/workflows/release.yml`). It builds a Release `.app`
and attaches it to a GitHub Release.

## How the shake works

The detector (`ShakeDrop/Sources/ShakeDetectorView.swift`) installs a local
`NSEvent` monitor and counts sign-flips in the cursor's `dx+dy` per sample.
Defaults: ~4 direction reversals within 0.8s, with at least 200pt of total
travel. Tunables are at the top of the file.

## Project layout

```
ShakeDrop/
├── ShakeDrop.xcodeproj/
├── .github/workflows/release.yml    # CI: build + tag-based release
└── ShakeDrop/
    ├── Resources/
    │   ├── Assets.xcassets/
    │   ├── Info.plist
    │   └── ShakeDrop.entitlements
    └── Sources/
        ├── ShakeDropApp.swift     # @main entry point (MenuBarExtra)
        ├── ContentView.swift      # popover content + status text
        ├── DropZoneView.swift     # file drop target UI
        ├── ShakeDetectorView.swift# NSView that detects mouse shaking
        └── AirDropSender.swift    # NSSharingService AirDrop wrapper
```

## License

MIT — see [LICENSE](LICENSE).
