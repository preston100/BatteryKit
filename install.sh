#!/bin/bash
# BatteryKit 2 installer — builds from source, removes the old BatteryKit,
# installs the always-on background service and the menu bar app.
# Run:  bash install.sh   (from inside the BatteryKit folder)
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
SUPPORT="/Library/Application Support/BatteryKit"
DAEMON_LABEL="com.batterykit.daemon"
AGENT_LABEL="com.batterykit.app"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
APP="/Applications/BatteryKit.app"
UID_NUM="$(id -u)"

say()  { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m✗ %s\033[0m\n" "$*"; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || fail "This build is for Apple silicon Macs."
[[ "$EUID" -ne 0 ]] || fail "Run without sudo: bash install.sh (it asks for your password when needed)."

# ---------------------------------------------------------------- build
say "Checking for Apple's command line tools"
if ! xcrun --find swiftc >/dev/null 2>&1; then
    xcode-select --install || true
    fail "Install the Command Line Tools from the popup, then run this script again."
fi

say "Building (takes about a minute)"
rm -rf "$BUILD"; mkdir -p "$BUILD"
FLAGS=(-O -swift-version 5 -target arm64-apple-macos26.0)

xcrun --sdk macosx swiftc "${FLAGS[@]}" \
    Shared/Shared.swift Shared/SMC.swift Daemon/main.swift \
    -o "$BUILD/batterykitd"

xcrun --sdk macosx swiftc "${FLAGS[@]}" -parse-as-library \
    Shared/Shared.swift Shared/SMC.swift App/Model.swift App/Views.swift \
    -o "$BUILD/BatteryKit"

# App bundle
B="$BUILD/BatteryKit.app"
mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources"
cp "$BUILD/BatteryKit" "$B/Contents/MacOS/BatteryKit"
cat > "$B/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BatteryKit</string>
    <key>CFBundleDisplayName</key><string>BatteryKit</string>
    <key>CFBundleIdentifier</key><string>com.batterykit.app</string>
    <key>CFBundleExecutable</key><string>BatteryKit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.9</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$B/Contents/Resources/AppIcon.icns" 2>/dev/null || true
codesign --force --sign - "$BUILD/batterykitd" >/dev/null
codesign --force --deep --sign - "$B" >/dev/null

# ---------------------------------------------------------------- remove old version
say "Removing the old BatteryKit (your password is needed)"
sudo -v
# Keep only the most recent previous install, out of sight.
BACKUP="$HOME/Library/Application Support/BatteryKit Backup"
sudo rm -rf "$BACKUP"
mkdir -p "$BACKUP"
shopt -s nullglob nocaseglob

for p in /Library/LaunchDaemons/*batterykit*.plist /Library/LaunchAgents/*batterykit*.plist; do
    label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$p" 2>/dev/null || basename "$p" .plist)"
    sudo launchctl bootout "system/$label" 2>/dev/null || true
    sudo launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    sudo mv "$p" "$BACKUP/" && echo "  moved $p"
done
for p in "$HOME"/Library/LaunchAgents/*batterykit*.plist; do
    label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$p" 2>/dev/null || basename "$p" .plist)"
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    mv "$p" "$BACKUP/" && echo "  moved $p"
done
shopt -u nocaseglob

sudo pkill -x batterykitd 2>/dev/null || true
pkill -x BatteryKit 2>/dev/null || true
sleep 1

for f in /usr/local/bin/batterykitd /usr/local/bin/batterykit /usr/local/sbin/batterykitd; do
    if [[ -e "$f" || -L "$f" ]]; then sudo mv "$f" "$BACKUP/" && echo "  moved $f"; fi
done
for a in "/Applications/BatteryKit.app" "$HOME/Applications/BatteryKit.app"; do
    if [[ -e "$a" ]]; then sudo mv "$a" "$BACKUP/" && echo "  moved $a"; fi
done
if [[ -d "$SUPPORT" ]]; then
    # Keep settings/history from a previous BatteryKit 2 install, drop anything else.
    if [[ -f "$SUPPORT/config.json" ]] && grep -q '"sailingGap"' "$SUPPORT/config.json"; then
        sudo rm -rf "$SUPPORT/bin"
    else
        sudo mv "$SUPPORT" "$BACKUP/" && echo "  moved $SUPPORT"
    fi
fi
sudo chown -R "$UID_NUM" "$BACKUP" 2>/dev/null || true
# Rename backed-up app bundles so Spotlight and Launchpad don't list them as apps.
for a in "$BACKUP"/*.app; do sudo mv "$a" "$a.old"; done
rmdir "$BACKUP" 2>/dev/null || true   # nothing was replaced: no backup folder needed

# ---------------------------------------------------------------- install service
say "Installing the background service"
sudo mkdir -p "$SUPPORT/bin"
sudo chmod 755 "$SUPPORT" "$SUPPORT/bin"
sudo install -m 755 -o root -g wheel "$BUILD/batterykitd" "$SUPPORT/bin/batterykitd"
sudo mkdir -p /usr/local/bin
sudo ln -sf "$SUPPORT/bin/batterykitd" /usr/local/bin/batterykitd

if [[ ! -f "$SUPPORT/config.json" ]]; then
    printf '{\n  "dischargeToLimit" : false,\n  "enabled" : true,\n  "heatProtection" : true,\n  "limit" : 80,\n  "maxTempC" : 35,\n  "sailingGap" : 5,\n  "topUp" : false\n}\n' \
        | sudo tee "$SUPPORT/config.json" >/dev/null
fi
sudo chown root:admin "$SUPPORT/config.json"
sudo chmod 664 "$SUPPORT/config.json"   # only admin accounts can change settings

sudo tee "$DAEMON_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$DAEMON_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$SUPPORT/bin/batterykitd</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>/Library/Logs/BatteryKit.log</string>
    <key>StandardErrorPath</key><string>/Library/Logs/BatteryKit.log</string>
</dict>
</plist>
PLIST
sudo chown root:wheel "$DAEMON_PLIST"
sudo chmod 644 "$DAEMON_PLIST"
sudo launchctl bootstrap system "$DAEMON_PLIST"
sudo launchctl enable "system/$DAEMON_LABEL"

# ---------------------------------------------------------------- install app
say "Installing the menu bar app"
sudo cp -R "$B" "$APP"
sudo chown -R "$UID_NUM":staff "$APP"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/BatteryKit</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$UID_NUM" "$AGENT_PLIST"

# The build folder holds a second copy of the app; remove it so only /Applications/BatteryKit.app shows up.
rm -rf "$BUILD"

# ---------------------------------------------------------------- report
sleep 4
say "Checking what your Mac allows"
sudo "$SUPPORT/bin/batterykitd" probe || true
echo
echo "Live status:"
batterykitd status | grep -E '"(mode|method|lastError)"' || true

say "Done"
[[ -d "$BACKUP" ]] && echo "  • Previous install backed up to: $BACKUP"
cat <<TXT
  • BatteryKit is in your menu bar and starts on its own at every login.
  • The limit is enforced by a background service that starts at boot,
    even before you log in. Nothing to set up again after restarts.
  • Turn OFF Apple's own controls so they don't fight BatteryKit:
      System Settings › Battery › (i) next to Charging
      → Optimized Battery Charging: off,  Charge Limit: 100%
  • Uninstall any time: bash uninstall.sh
TXT
