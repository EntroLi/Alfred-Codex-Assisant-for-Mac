from pathlib import Path
import json,plistlib,sys
root=Path(__file__).resolve().parent.parent
v=json.loads((root/'VERSION.json').read_text())
info={'CFBundleExecutable':'SuiAssistant','CFBundleIdentifier':v['bundleID'],
      'CFBundleName':v['displayName'],'CFBundleDisplayName':v['displayName'],
      'CFBundleIconFile':'AppIcon','CFBundlePackageType':'APPL','CFBundleShortVersionString':v['version'],
      'CFBundleVersion':v['build'],'LSMinimumSystemVersion':'12.0','LSUIElement':True,
      'CFBundleURLTypes':[{'CFBundleURLName':'Alfred Desktop','CFBundleURLSchemes':['alfred-batcave']}],
      'NSCalendarsFullAccessUsageDescription':'Alfred读取你指定范围的日历；手动写入仅执行你逐项预览并批准的批次。',
      'NSRemindersFullAccessUsageDescription':'Alfred读取你指定的提醒列表；手动写入仅执行你逐项预览并批准的批次。',
      'NSCalendarsUsageDescription':'Alfred读取指定范围的日历，写入需另外批准具体批次。',
      'NSRemindersUsageDescription':'Alfred读取指定提醒列表，写入需另外批准具体批次。'}
(Path(sys.argv[1])/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
