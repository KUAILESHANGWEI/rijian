#!/bin/sh
set -eu
RIJIAN_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$RIJIAN_ROOT" <<'PY'
import pathlib,sys,shutil
root=pathlib.Path(sys.argv[1])
web=root/'native/ios/Web'
if web.exists():shutil.rmtree(web)
shutil.copytree(root/'dist',web,ignore=shutil.ignore_patterns('iphone.html'))
shutil.copy2(root/'native/shared/native.js',web/'native.js')
p=web/'index.html';p.write_text(p.read_text().replace('</body>','<script src="native.js"></script></body>'))
PY
mkdir -p "$RIJIAN_ROOT/exports"
xcodebuild -project "$RIJIAN_ROOT/native/ios/Rijian.xcodeproj" -scheme Rijian -configuration Release -destination 'generic/platform=iOS' -archivePath "$RIJIAN_ROOT/exports/Rijian.xcarchive" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$RIJIAN_ROOT/exports/Rijian.xcarchive" -exportPath "$RIJIAN_ROOT/exports/ios" -exportOptionsPlist "$RIJIAN_ROOT/native/ios/ExportOptions.plist" -allowProvisioningUpdates
cp "$RIJIAN_ROOT/exports/ios/Rijian.ipa" "$RIJIAN_ROOT/exports/日缄-1.0-iPhone测试版.ipa"
