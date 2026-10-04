"""Check Alfred's detail panel in a separate full-screen QA host; no production data or host UI automation."""
from pathlib import Path
import json, plistlib, subprocess, time

root = Path(__file__).resolve().parent.parent
version = json.loads((root / 'VERSION.json').read_text())['version']
bundle = root / '.staging/AlfredFullscreenQA.app'
binary = bundle / 'Contents/MacOS/AlfredFullscreenQA'
binary.parent.mkdir(parents=True, exist_ok=True)
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.alfred.fullscreen-qa',
    'CFBundleName': 'Alfred Fullscreen QA', 'CFBundleExecutable': 'AlfredFullscreenQA'}))
subprocess.run(['xcrun', 'swiftc', str(root / 'tools/fullscreen_qa.swift'),
                '-o', str(binary), '-framework', 'AppKit'], check=True)
marker = root / '.staging/fullscreen-entered'
marker.unlink(missing_ok=True)
host = subprocess.Popen([str(binary), str(marker)])
try:
    for _ in range(100):
        if marker.exists():
            break
        time.sleep(.1)
    assert marker.exists(), 'QA host did not enter full screen'
    stage = Path((root / '.staging/latest-path.txt').read_text().strip())
    report = root / f'evidence/panel-fullscreen-{version}.json'
    candidate = subprocess.run([str(stage / 'Contents/MacOS/SuiAssistant'),
                                '--verify-panel', str(report)], timeout=15)
    data = json.loads(report.read_text())
    data['separateQAHostEnteredFullScreen'] = True
    report.write_text(json.dumps(data, indent=2))
    print(json.dumps(data))
    assert candidate.returncode == 0
finally:
    host.terminate()
    host.wait(timeout=10)
