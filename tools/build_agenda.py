#!/usr/bin/env python3
"""Build an isolated on-demand development bundle; never install or launch it."""
from pathlib import Path
import argparse, json, os, plistlib, shutil, subprocess, uuid

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reuse', type=Path, help='Replace only the explicitly identified task development bundle')
args = parser.parse_args()
env = os.environ.copy()
env['CLANG_MODULE_CACHE_PATH'] = str(root / '.build/module-cache')
env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / '.build/module-cache')
subprocess.run(['swift', 'build', '--disable-sandbox', '-c', 'release',
                '-Xswiftc', '-file-prefix-map', '-Xswiftc', str(root) + '=.',
                '-Xswiftc', '-debug-prefix-map', '-Xswiftc', str(root) + '=.'], cwd=root, env=env, check=True)
bundle = args.reuse.resolve() if args.reuse else root / '.staging' / ('agenda-' + str(uuid.uuid4())) / 'Alfred.app'
if args.reuse:
    assert bundle.is_relative_to(root / '.staging') and bundle.name == 'Alfred.app'
    assert plistlib.loads((bundle / 'Contents/Info.plist').read_bytes()).get('AlfredAgendaOnly') is True
(bundle / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
shutil.copy2(root / '.build/release/SuiAssistant', bundle / 'Contents/MacOS/SuiAssistant')
subprocess.run(['python3', str(root / 'tools/package_info.py'), str(bundle)], check=True)
info_path = bundle / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['AlfredAgendaOnly'] = True
info.pop('CFBundleURLTypes', None)
info.pop('CFBundleIconFile', None)
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
# Separate pointer from the release/deploy pointer. Status/read do not launch NSApplication.
(root / '.staging/agenda-path.txt').write_text(str(bundle) + '\n')
print(json.dumps({'bundle': str(bundle), 'installed': False, 'launched': False,
                  'mode': 'on-demand development; not a release package'}))
