#!/bin/bash
set -e

DERIVED=$(ls -d "$HOME/Library/Developer/Xcode/DerivedData/Parrrot-"*/Build/Products/Debug/parrrot.app 2>/dev/null | head -1)
DEST="/Applications/parrrot.app"
CERT="Papuga Dev"

echo "→ Killing parrrot..."
pkill -9 -f "parrrot" 2>/dev/null || true; sleep 0.5

echo "→ Building..."
xcodebuild -project Parrrot.xcodeproj -scheme parrrot -configuration Debug clean build 2>&1 | grep -E "(error:|BUILD|warning:.*sign)"

echo "→ Deploying..."
rm -rf "$DEST"
cp -R "$DERIVED" "$DEST"

echo "→ Signing..."
find "$DEST" -name "*.dylib" -exec codesign --force --sign "$CERT" {} \;
codesign --force --sign "$CERT" "$DEST"

echo "→ Launching..."
open "$DEST"
echo "✓ Done"
