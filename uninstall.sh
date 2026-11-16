#!/bin/bash
# Removes BatteryKit 2 and hands charging back to macOS.
set -uo pipefail
UID_NUM="$(id -u)"
SUPPORT="/Library/Application Support/BatteryKit"

echo "Removing BatteryKit (your password is needed)…"
sudo -v
launchctl bootout "gui/$UID_NUM/com.batterykit.app" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/com.batterykit.app.plist"
pkill -x BatteryKit 2>/dev/null

# Stopping the service makes it restore normal charging before it exits.
sudo launchctl bootout system/com.batterykit.daemon 2>/dev/null
sleep 2
[[ -x "$SUPPORT/bin/batterykitd" ]] && sudo "$SUPPORT/bin/batterykitd" release >/dev/null 2>&1

sudo rm -f /Library/LaunchDaemons/com.batterykit.daemon.plist /usr/local/bin/batterykitd
sudo rm -rf "$SUPPORT" /Applications/BatteryKit.app
echo "Done. Charging is back to normal. (Log kept at /Library/Logs/BatteryKit.log)"
