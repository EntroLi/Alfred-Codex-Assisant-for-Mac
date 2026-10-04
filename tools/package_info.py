from pathlib import Path
import json,plistlib,sys
root=Path(__file__).resolve().parent.parent
v=json.loads((root/'VERSION.json').read_text())
info={'CFBundleExecutable':'SuiAssistant','CFBundleIdentifier':v['bundleID'],
      'CFBundleName':v['displayName'],'CFBundleDisplayName':v['displayName'],
      'CFBundleIconFile':'AppIcon','CFBundlePackageType':'APPL','CFBundleShortVersionString':v['version'],
      'CFBundleVersion':v['build'],'LSMinimumSystemVersion':'12.0','LSUIElement':True,
      'CFBundleURLTypes':[{'CFBundleURLName':'Alfred Desktop','CFBundleURLSchemes':['alfred-batcave']}],
      'NSCalendarsFullAccessUsageDescription':'Alfred读取下一场日程并在开始前提醒；不会新增、修改或删除日程。',
      'NSRemindersFullAccessUsageDescription':'Alfred读取最高优先级的未完成提醒事项；不会修改或完成你的事项。',
      'NSCalendarsUsageDescription':'Alfred读取下一场日程并在开始前提醒；不会修改日程。',
      'NSRemindersUsageDescription':'Alfred读取最高优先级未完成事项；不会修改事项。'}
(Path(sys.argv[1])/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
