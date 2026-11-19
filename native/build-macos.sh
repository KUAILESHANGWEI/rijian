#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/exports/日缄.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 - "$ROOT" "$APP" <<'PY'
import sys,pathlib,shutil,plistlib
root,app=map(pathlib.Path,sys.argv[1:])
web=app/'Contents/Resources/Web'
if web.exists():shutil.rmtree(web)
shutil.copytree(root/'dist',web,ignore=shutil.ignore_patterns('iphone.html'))
shutil.copy2(root/'native/macos/native.js',web/'native.js')
p=web/'index.html';p.write_text(p.read_text().replace('</body>','<script src="native.js"></script></body>'))
info={'CFBundleIdentifier':'com.shangweiqiu.rijian.mac','CFBundleName':'日缄','CFBundleDisplayName':'日缄','CFBundleExecutable':'Rijian','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'2026111908','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'CFBundleIconFile':'AppIcon','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swiftc -parse-as-library -O -target arm64-apple-macos13.0 "$ROOT/native/macos/LocalAppServer.swift" "$ROOT/native/macos/RijianMac.swift" -o "$APP/Contents/MacOS/Rijian" -framework AppKit -framework WebKit -framework Network -framework UserNotifications -framework AVFoundation
ICONSET="$ROOT/exports/MacApp.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/native/ios/Assets.xcassets/AppIcon.appiconset/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/native/ios/Assets.xcassets/AppIcon.appiconset/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/exports/日缄-1.0-Mac.zip"
