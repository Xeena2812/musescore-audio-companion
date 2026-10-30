#!/bin/sh
# Builds ~/Applications/AudioCompanionHandler.app (a tiny URL-scheme handler)
# and registers it with Launch Services. No root. Undo: ./install-macos.sh --uninstall
set -e
here=$(cd "$(dirname "$0")" && pwd)
app="$HOME/Applications/AudioCompanionHandler.app"

if [ "$1" = "--uninstall" ]; then rm -rf "$app"; echo "Removed."; exit 0; fi

mkdir -p "$app/Contents/MacOS"
cp "$here/audiocompanion-launcher-mac.sh" "$app/Contents/MacOS/launcher.sh"
chmod +x "$app/Contents/MacOS/launcher.sh"
# The app receives the URL as an Apple Event, not argv, so use a tiny AppleScript-free
# wrapper: osacompile an applet that forwards the URL to launcher.sh.
tmp=$(mktemp -d)
cat > "$tmp/h.applescript" <<'AS'
on open location u
	do shell script quoted form of (POSIX path of (path to me) & "Contents/MacOS/launcher.sh") & " " & quoted form of u & " >/dev/null 2>&1 &"
end open location
AS
rm -rf "$app.tmp"; osacompile -o "$app.tmp" "$tmp/h.applescript"
cp "$app/Contents/MacOS/launcher.sh" "$app.tmp/Contents/MacOS/launcher.sh"
rm -rf "$app"; mv "$app.tmp" "$app"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.audiocompanion.handler" "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string Audio Companion" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string audiocompanion" "$app/Contents/Info.plist"
codesign --force --sign - "$app" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed. Test: open audiocompanion://start"
