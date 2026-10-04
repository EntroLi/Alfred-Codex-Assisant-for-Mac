from pathlib import Path
import hashlib,json,plistlib,sys,subprocess
root=Path(__file__).resolve().parent.parent
app=Path(sys.argv[1]);v=json.loads((root/'VERSION.json').read_text())
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']==v['bundleID']
assert info['CFBundleShortVersionString']==v['version'] and info['CFBundleVersion']==v['build']
assert info['CFBundleDisplayName']==v['displayName'] and info['LSUIElement']
assert info['CFBundleIconFile']=='AppIcon'
icon=app/'Contents/Resources'/(info['CFBundleIconFile']+'.icns')
assert icon.is_file() and icon.read_bytes()[:4]==b'icns', 'Declared application icon must be packaged'
assert (app/'Contents/MacOS'/info['CFBundleExecutable']).stat().st_mode & 0o111
for bundle, executable in [('PlugIns/AlfredDesktop.appex','AlfredDesktop')]:
 p=app/'Contents'/bundle
 child=plistlib.loads((p/'Contents/Info.plist').read_bytes())
 assert child['CFBundleShortVersionString']==v['version'] and child['CFBundleVersion']==v['build']
 assert (p/'Contents/MacOS'/executable).stat().st_mode & 0o111
 result=subprocess.run(['codesign','-d','--entitlements',':-',str(p)],capture_output=True,check=True)
 ent=plistlib.loads(result.stdout)
 assert ent=={'com.apple.security.app-sandbox':True,'com.apple.security.temporary-exception.files.home-relative-path.read-only':['/Library/Application Support/CodexQuotaBar/native-widget-v1.json']}
 if executable=='AlfredDesktop':
  symbols=subprocess.run(['nm','-u',str(p/'Contents/MacOS'/executable)],capture_output=True,text=True,check=True).stdout
  assert '_NSExtensionMain' in symbols, 'Widget must use the system extension startup entry'
for p in (root/'Resources').rglob('*'):
 if p.is_file():
  q=app/'Contents/Resources'/p.relative_to(root/'Resources')
  assert hashlib.sha256(p.read_bytes()).digest()==hashlib.sha256(q.read_bytes()).digest(),p
print('包身份、版本、可执行文件和全部Resources哈希通过')
