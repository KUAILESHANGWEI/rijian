#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/exports/日缄.app"
python3 - "$ROOT" <<'PY'
import pathlib,sys,shutil
root=pathlib.Path(sys.argv[1]);web=root/'native/macos/Web'
if web.exists():shutil.rmtree(web)
shutil.copytree(root/'dist',web,ignore=shutil.ignore_patterns('iphone.html'))
shutil.copy2(root/'native/macos/native.js',web/'native.js')
p=web/'index.html';p.write_text(p.read_text().replace('</body>','<script src="native.js"></script></body>'))
PY
xcodebuild -project "$ROOT/native/macos/RijianMac.xcodeproj" -scheme RijianMac -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/exports/mac-cloud-build" -allowProvisioningUpdates build
# The Xcode-signed bundle and embedded provisioning profile are required by CloudKit.
python3 - "$APP" <<'PY'
import pathlib,shutil,sys
p=pathlib.Path(sys.argv[1])
if p.exists():shutil.rmtree(p)
PY
ditto "$ROOT/exports/mac-cloud-build/Build/Products/Release/RijianMac.app" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/exports/日缄-1.0-Mac.zip"
