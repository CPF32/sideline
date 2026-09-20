#!/bin/sh
# Capture 6.7" App Store screenshots, then compose connected marketing frames.
# App Store Connect accepts 1284×2778 (portrait) for this display size.
#
# Usage:
#   ./Scripts/capture_app_store_screenshots.sh              # raw + marketing
#   ./Scripts/capture_app_store_screenshots.sh --raw-only
#   ./Scripts/capture_app_store_screenshots.sh --compose-only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/AppStoreScreenshots/6.7-inch"
TARGET_WIDTH=1284
TARGET_HEIGHT=2778
BUNDLE_ID="com.cpf32.sideline"
DERIVED_DATA="$ROOT/.screenshot-derived-data"
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Sideline.app"
LOG="$ROOT/AppStoreScreenshots/last-capture.log"

RAW_ONLY=0
COMPOSE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --raw-only) RAW_ONLY=1 ;;
    --compose-only) COMPOSE_ONLY=1 ;;
  esac
done

compose_marketing() {
  echo "→ Composing connected marketing frames"
  VENV="$ROOT/Scripts/.venv-screenshots"
  if [ -x "$VENV/bin/python3.11" ]; then
    PYTHON="$VENV/bin/python3.11"
  else
    PYTHON="$VENV/bin/python"
  fi
  if [ ! -x "$PYTHON" ] || ! "$PYTHON" -c "import PIL" >/dev/null 2>&1; then
    echo "  Creating screenshot venv…"
    /opt/homebrew/bin/python3.11 -m venv "$VENV"
    "$VENV/bin/python3.11" -m pip install -q Pillow
    PYTHON="$VENV/bin/python3.11"
  fi
  "$PYTHON" "$ROOT/Scripts/compose_marketing_screenshots.py"
}

if [ "$COMPOSE_ONLY" -eq 1 ]; then
  compose_marketing
  exit 0
fi

pick_simulator() {
  if [ -n "${SIMULATOR_UDID:-}" ]; then
    echo "$SIMULATOR_UDID"
    return
  fi
  for name in "iPhone 17 Pro Max" "iPhone 16 Pro Max" "iPhone 15 Pro Max" "iPhone 14 Pro Max"; do
    udid="$(xcrun simctl list devices available | sed -n "s/.*$name (\([A-F0-9-]*\)).*/\1/p" | head -1)"
    if [ -n "$udid" ]; then
      echo "$udid"
      return
    fi
  done
  xcrun simctl list devices available | sed -n 's/.*iPhone.*(\([A-F0-9-]*\)).*/\1/p' | head -1
}

mkdir -p "$OUT" "$(dirname "$LOG")"
UDID="$(pick_simulator)"
if [ -z "$UDID" ]; then
  echo "No available iPhone simulator found. Create one in Xcode → Window → Devices and Simulators."
  exit 1
fi
echo "→ Using simulator $UDID"

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$ROOT" && xcodegen generate >/dev/null)
fi

echo "→ Building Sideline for simulator"
set +e
xcodebuild \
  -project "$ROOT/Sideline.xcodeproj" \
  -scheme "Sideline" \
  -destination "id=$UDID" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >"$LOG" 2>&1
BUILD_STATUS=$?
set -e

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "✗ Build failed. Swift errors:"
  rg -n "error: " "$LOG" | head -40 || true
  echo ""
  echo "Full log: $LOG"
  exit "$BUILD_STATUS"
fi

echo "→ Booting simulator"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "→ Cleaning status bar for marketing screenshots"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 >/dev/null

xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

capture() {
  tab="$1"
  file="$2"
  echo "  • $file ($tab)"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    -ScreenshotDemo \
    -ScreenshotTab "$tab" >/dev/null
  sleep 3.5
  xcrun simctl io "$UDID" screenshot "$OUT/$file"
  sips -z "$TARGET_HEIGHT" "$TARGET_WIDTH" "$OUT/$file" --out "$OUT/$file" >/dev/null
}

capture team "01-team.png"
capture league "02-league.png"
capture agents "03-agents.png"
capture approvals "04-approvals.png"
capture settings "05-settings.png"

xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true

echo "→ Saved raw captures to $OUT (${TARGET_WIDTH}×${TARGET_HEIGHT})"
ls -lh "$OUT"

if [ "$RAW_ONLY" -eq 0 ]; then
  compose_marketing
fi
