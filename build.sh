#!/bin/bash
# Build Leaf.app, ad-hoc sign it, install to ~/Applications and register with Launch Services.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Leaf"

APP="Leaf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Leaf"
cp Info.plist "$APP/Contents/Info.plist"
cp -R web "$APP/Contents/Resources/web"
if [ -f icon/Leaf.icns ]; then
    cp icon/Leaf.icns "$APP/Contents/Resources/Leaf.icns"
fi

codesign --force --deep --sign - "$APP"

DEST="$HOME/Applications"
mkdir -p "$DEST"
if pgrep -x Leaf >/dev/null; then
    osascript -e 'tell application id "local.leaf.Leaf" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Leaf >/dev/null || break; sleep 0.3; done
    pkill -x Leaf 2>/dev/null || true
fi
rm -rf "$DEST/Leaf.app"
cp -R "$APP" "$DEST/Leaf.app"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Leaf.app"
echo "Installed $DEST/Leaf.app"
