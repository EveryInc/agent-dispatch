#!/bin/bash
# Builds build/AgentDispatch.app with the Swift command-line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AgentDispatch.app"
mkdir -p build
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26.0" Sources/*.swift -o build/AgentDispatch-bin

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv build/AgentDispatch-bin "$APP/Contents/MacOS/AgentDispatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature with an explicit designated requirement, so the Photos permission belongs to the bundle
# identifier and survives a rebuild (the same trick Clipshot uses for Screen Recording).
codesign --force --sign - -r='designated => identifier "com.every.agentdispatch"' "$APP" >/dev/null 2>&1
echo "Built $APP"
