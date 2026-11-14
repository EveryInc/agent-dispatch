#!/bin/bash
# install.sh [install|uninstall|status]
# install: builds the app, copies it to ~/Applications and loads a LaunchAgent that runs one pass a minute
# in the logged-in desktop session (Photos and Clipshot are only reachable there).
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.danshipper.phonerecordings"
APP="$HOME/Applications/PhoneRecordings.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/PhoneRecordings"

case "${1:-install}" in
install)
    ./build.sh
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    mkdir -p "$HOME/Applications" "$SUPPORT"
    rm -rf "$APP"
    cp -R build/PhoneRecordings.app "$APP"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/PhoneRecordings</string>
    <string>run</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key>
  <dict><key>HOME</key><string>$HOME</string></dict>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$SUPPORT/launchd.err.log</string>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed. Log: $SUPPORT/watcher.log"
    ;;
uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Stopped. The app is still at $APP and nothing in ~/Recordings was touched."
    ;;
status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state =|runs =|last exit code" || echo "Not loaded."
    "$APP/Contents/MacOS/PhoneRecordings" status
    ;;
*)
    echo "Use: install.sh install|uninstall|status"; exit 2 ;;
esac
