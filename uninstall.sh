#!/bin/bash
#
# 充电功率 uninstaller.
#   curl -fsSL https://raw.githubusercontent.com/1c7/BatteryWatts/main/uninstall.sh | bash
#
set -euo pipefail

APP_NAME="BatteryWatts"
APP_BUNDLE="充电功率.app"
LABEL="com.jpert.batterywatts"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Uninstalling $APP_BUNDLE (will ask for sudo password)"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
rm -f "$PLIST"
sudo rm -rf "/Applications/$APP_BUNDLE"
echo "==> Removed. (The menu-bar icon disappears once the app stops.)"
