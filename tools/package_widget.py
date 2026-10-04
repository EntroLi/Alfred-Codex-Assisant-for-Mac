from pathlib import Path
import json, plistlib, sys
root = Path(__file__).resolve().parent.parent
version = json.loads((root / 'VERSION.json').read_text())
info = dict(CFBundleExecutable='AlfredDesktop', CFBundleIdentifier=version['bundleID'] + '.desktop',
    CFBundleName='Alfred', CFBundleDisplayName='Alfred', CFBundlePackageType='XPC!',
    CFBundleShortVersionString=version['version'], CFBundleVersion=version['build'],
    CFBundleInfoDictionaryVersion='6.0', CFBundleDevelopmentRegion='zh_CN', CFBundleSupportedPlatforms=['MacOSX'],
    LSMinimumSystemVersion='14.0', NSExtension={'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'})
(Path(sys.argv[1]) / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
if len(sys.argv) > 2:
    writer = dict(CFBundleExecutable='AlfredSnapshotWriter', CFBundleIdentifier=version['bundleID']+'.snapshot-writer',
        CFBundleName='Alfred Snapshot Writer', CFBundlePackageType='APPL', LSUIElement=True,
        CFBundleShortVersionString=version['version'], CFBundleVersion=version['build'])
    (Path(sys.argv[2])/'Contents/Info.plist').write_bytes(plistlib.dumps(writer))
