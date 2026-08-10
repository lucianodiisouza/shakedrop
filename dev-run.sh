#!/bin/bash
#
# dev-run.sh — build ShakeDrop and sign it with a STABLE Apple
# Development certificate, so the Input Monitoring (TCC) grant
# survives rebuilds instead of breaking every time (which is what
# ad-hoc signing does — a new code hash each build → macOS treats it
# as a different app → permission silently lost → tap never fires).
#
# Usage:  ./dev-run.sh [--launch]
#
set -euo pipefail
cd "$(dirname "$0")"

# Your stable signing identity. `security find-identity -v -p codesigning`
# lists the options; this is the one tied to lucmanut@gmail.com.
CERT="${SHAKEDROP_CERT:-F0F5F5D179A60CD4DAB636DFBCA7225C0F488C97}"
SCHEME="ShakeDrop"
CONFIG="Debug"

echo "==> Killing any running ShakeDrop"
pkill -x ShakeDrop 2>/dev/null || true

echo "==> Building ($CONFIG, ad-hoc first)"
xcodebuild -project ShakeDrop.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual \
  build >/tmp/shakedrop-build.log 2>&1 || { tail -25 /tmp/shakedrop-build.log; exit 1; }

DD=$(xcodebuild -project ShakeDrop.xcodeproj -scheme "$SCHEME" \
      -showBuildSettings -configuration "$CONFIG" 2>/dev/null \
      | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$DD/ShakeDrop.app"

echo "==> Re-signing with stable cert: $CERT"
find "$APP/Contents/MacOS" -name "*.dylib" -print0 \
  | xargs -0 -I{} codesign --force --sign "$CERT" --timestamp=none {} >/dev/null 2>&1 || true
codesign --force --sign "$CERT" \
  --entitlements ShakeDrop/Resources/ShakeDrop.entitlements \
  --timestamp=none "$APP"

echo "==> Verifying signature"
codesign --verify --strict "$APP" && echo "signature OK"
echo "App: $APP"

if [[ "${1:-}" == "--launch" ]]; then
  echo "==> Launching"
  open "$APP"
fi
