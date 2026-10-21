#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
APP='build/Screen Recorder.app'
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ARCH="$(uname -m)"
swiftc -parse-as-library -O -target "${ARCH}-apple-macos15.0" Sources/ScreenRecorderApp.swift -o "$APP/Contents/MacOS/ScreenRecorder"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
print "Built: $PWD/$APP"
