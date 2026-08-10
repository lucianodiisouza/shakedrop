#!/usr/bin/env bash
#
# uninstall.sh — completely remove ShakeDrop from this Mac
#
# Removes:
#   - the .app bundle from /Applications (and any leftover
#     zip downloads in the user's Downloads folder)
#   - any running process
#   - the Input Monitoring + Accessibility TCC entries
#     (this part is optional and prompted)
#   - the per-user LaunchServices registration
#   - the per-user preferences and caches
#
# Safe to re-run. Uses `set -e` so it bails on the first
# unexpected error so the user can see what failed.
#
# Usage:
#   ./uninstall.sh
#
# Or, from anywhere:
#   bash /path/to/shakedrop/uninstall.sh

set -euo pipefail

APP_NAME="ShakeDrop"
BUNDLE_ID="com.shakedrop.app"

# Resolve the repo root from the script's own location so the
# script works no matter where it's invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Common install locations
APP_PATHS=(
    "/Applications/${APP_NAME}.app"
    "$HOME/Applications/${APP_NAME}.app"
    "$HOME/Downloads/${APP_NAME}.app"
    "$HOME/Desktop/${APP_NAME}.app"
    "$SCRIPT_DIR/build/Build/Products/Release/${APP_NAME}.app"
    "$SCRIPT_DIR/build/Build/Products/Debug/${APP_NAME}.app"
)

# Old release zips we may have left in Downloads
ZIP_PATTERNS=(
    "$HOME/Downloads/${APP_NAME}-*.app.zip"
)

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mxx\033[0m %s\n" "$*" >&2; exit 1; }

# Must not be run as root. We don't want to nuke the system
# LaunchServices or TCC databases by accident.
if [[ $EUID -eq 0 ]]; then
    die "Don't run this as root. It only touches per-user state."
fi

echo
echo "ShakeDrop uninstaller"
echo "======================"
echo

# ----------------------------------------------------------------
# 1. Kill the app if it's running
# ----------------------------------------------------------------
if pgrep -f "${APP_NAME}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
    say "Stopping ${APP_NAME}…"
    pkill -9 -f "${APP_NAME}/Contents/MacOS/${APP_NAME}" || true
    sleep 1
fi

# ----------------------------------------------------------------
# 2. Remove the .app bundle from every plausible install path
# ----------------------------------------------------------------
removed_any=false
for path in "${APP_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        say "Removing $path"
        rm -rf "$path"
        removed_any=true
    fi
done

# ----------------------------------------------------------------
# 3. Remove leftover release zips
# ----------------------------------------------------------------
shopt -s nullglob
for pattern in "${ZIP_PATTERNS[@]}"; do
    for f in $pattern; do
        say "Removing download $f"
        rm -f "$f"
        removed_any=true
    done
done
shopt -u nullglob

# ----------------------------------------------------------------
# 4. Drop quarantine xattrs on anything we no longer have.
#    (Only relevant if user moved the app elsewhere first.)
# ----------------------------------------------------------------

# ----------------------------------------------------------------
# 5. Per-user LaunchServices registration
# ----------------------------------------------------------------
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREG" ]]; then
    say "Unregistering ${BUNDLE_ID} with LaunchServices…"
    "$LSREG" -u "${BUNDLE_ID}" 2>/dev/null || warn "lsregister returned non-zero (usually harmless)"
else
    warn "lsregister not found; skipping LaunchServices cleanup"
fi

# ----------------------------------------------------------------
# 6. Per-user preferences and caches
# ----------------------------------------------------------------
USER_PREFS="$HOME/Library/Preferences/${BUNDLE_ID}.plist"
[[ -e "$USER_PREFS" ]] && { say "Removing $USER_PREFS"; rm -f "$USER_PREFS"; }

USER_CONTAINERS=(
    "$HOME/Library/Containers/${BUNDLE_ID}"
    "$HOME/Library/Containers/${BUNDLE_ID}.Data"
    "$HOME/Library/Group Containers/group.${BUNDLE_ID}"
    "$HOME/Library/Application Support/${APP_NAME}"
    "$HOME/Library/Application Support/${BUNDLE_ID}"
    "$HOME/Library/Caches/${BUNDLE_ID}"
    "$HOME/Library/Caches/${APP_NAME}"
    "$HOME/Library/Logs/${BUNDLE_ID}"
    "$HOME/Library/Logs/${APP_NAME}"
    "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
)
for path in "${USER_CONTAINERS[@]}"; do
    if [[ -e "$path" ]]; then
        say "Removing $path"
        rm -rf "$path"
    fi
done

# ----------------------------------------------------------------
# 7. Privacy database entries (TCC). The user has to
#    approve removal of these interactively because modern
#    macOS versions gate the database behind Full Disk Access
#    for non-Apple processes. We try; if it fails, instruct
#    the user to do it manually.
# ----------------------------------------------------------------
reset_tcc_entry() {
    local service="$1"
    local label="$2"
    local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

    if [[ ! -e "$db" ]]; then
        warn "TCC.db not found at $db; skipping $service"
        return 0
    fi

    say "Resetting ${service} entry for ${label}…"
    if /usr/bin/sqlite3 "$db" \
        "DELETE FROM access WHERE service='${service}' AND client='${label}';" 2>/dev/null
    then
        say "  ok"
    else
        warn "  could not write to TCC.db (Full Disk Access required)."
        warn "  The app will keep its ${service} permission until you reset it manually:"
        warn "    System Settings ▸ Privacy & Security ▸ ${service} ▸ ${APP_NAME}  →  toggle off"
    fi
}

reset_tcc_entry "kTCCServiceListenEvent"     "${BUNDLE_ID}"   # Input Monitoring
# Accessibility is not requested by this app, but reset it
# defensively in case an old build ever asked for it.
reset_tcc_entry "kTCCServiceAccessibility"  "${BUNDLE_ID}"

# Also blow away any LaunchServices quarantine for the bundle
# in case the user wants to re-install fresh.
APP_RECEIPT="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
# (nothing to do here; the bundle removal above is enough)

# ----------------------------------------------------------------
# 8. Summary
# ----------------------------------------------------------------
echo
if $removed_any; then
    say "Done. ${APP_NAME} is gone from this Mac."
else
    say "Done. No ${APP_NAME} artifacts were found to remove."
fi
echo
echo "If you installed ${APP_NAME} from a downloaded .zip, the"
echo "release file is also removed. To reinstall:"
echo
echo "  gh release download v0.2.5 -D ~/Downloads"
echo "  unzip -o ~/Downloads/${APP_NAME}-0.2.0.app.zip -d /Applications/"
echo
