# ShakeDrop

A tiny free/open-source macOS menu-bar app. Click and hold a file in Finder,
shake your mouse, and a small drop-target window appears near the cursor.
Release the file on it and AirDrop opens.

Built with SwiftUI + AppKit + a global `CGEventTap` for the shake gesture.
No third-party dependencies. macOS 13+.

## How it works

1. Click the hand icon in the menu bar the first time — the app asks for
   **Input Monitoring** permission. (Required because the shake is detected
   system-wide, not just inside our window.)
2. In Finder, click and hold a file (without releasing).
3. Shake your mouse. A small square, semi-transparent window with a dashed
   border appears next to the cursor.
4. Drop the file on it. The AirDrop share sheet opens with that file
   selected.

If you don't drop anything within 8 seconds, the window dismisses itself.

## Permissions

ShakeDrop needs **Input Monitoring** (System Settings ▸ Privacy & Security
▸ Input Monitoring) to detect the shake globally. The app does **not**
require Accessibility, Full Disk Access, or Automation.

If you deny the permission, you can re-grant it later by opening
System Settings, finding ShakeDrop under Input Monitoring, and toggling
it on. The app picks up the new state on the next shake attempt.

## Status bar

Icon: SF Symbol `hand.draw` (closed hand with extended index finger inside
a circle). The menu has:

- **Open ShakeDrop** — verifies Input Monitoring permission and starts the
  global shake monitor if it isn't already running.
- **About ShakeDrop**
- **Quit ShakeDrop** (⌘Q)

## Running an unsigned build on macOS

Gatekeeper blocks unsigned apps on first launch. Two clean ways around it.

### Build with `xcodebuild` (recommended)

```sh
xcodebuild -project ShakeDrop.xcodeproj -scheme ShakeDrop \
           -configuration Debug build \
           CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

Find the output and open it:

```sh
DD=$(xcodebuild -project ShakeDrop.xcodeproj -scheme ShakeDrop \
              -showBuildSettings -configuration Debug 2>/dev/null \
              | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR /{print $2; exit}')
open "$DD/ShakeDrop.app"
```

### Run from Xcode

Open the project, select the `ShakeDrop` scheme, press ⌘R.

### If macOS still blocks it

```sh
xattr -dr com.apple.quarantine /path/to/ShakeDrop.app
```

Or right-click the app in Finder → **Open** → **Open** in the dialog.
One-time approval per machine.

## Releasing

Push a `vX.Y.Z` tag to trigger the GitHub Actions release workflow
(`.github/workflows/release.yml`). It builds a Release `.app`, zips it with
`ditto`, and attaches it to a GitHub Release with install instructions.

## Project layout

```
ShakeDrop/
├── ShakeDrop.xcodeproj/
├── .github/workflows/release.yml    # CI: build + tag-based release
└── ShakeDrop/
    ├── Resources/
    │   ├── Assets.xcassets/
    │   ├── Info.plist
    │   └── ShakeDrop.entitlements  # sandbox + Input Monitoring
    └── Sources/
        ├── ShakeDropApp.swift     # @main, AppDelegate
        ├── AppCoordinator.swift   # wires monitor -> window -> AirDrop
        ├── ShakeMonitor.swift     # CGEventTap global shake detector
        ├── DropTargetWindow.swift # floating drop target (NSPanel)
        └── AirDropSender.swift    # NSSharingService AirDrop wrapper
```

## License

MIT — see [LICENSE](LICENSE).
