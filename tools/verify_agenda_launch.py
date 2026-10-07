#!/usr/bin/env python3
"""Verify one normal macOS launch of the staging app, using only --agenda status.

Run through a platform-approved normal Mac command context. This script never
requests privacy access, reads Apple entries, retries, installs or starts services.
"""
from pathlib import Path
import datetime
import json
import os
import plistlib
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parent.parent


def main():
    if len(sys.argv) != 1:
        raise ValueError('No arguments accepted; this verifier only runs --agenda status')
    app = Path((root / '.staging/agenda-path.txt').read_text().strip()).resolve()
    if not app.is_relative_to(root / '.staging') or app.name != 'Alfred.app':
        raise ValueError('Pointer must identify the project staging Alfred.app')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('AlfredAgendaOnly') is not True
            or info.get('CFBundleIdentifier') != 'local.codex.quota-bar'
            or info.get('CFBundleExecutable') != 'SuiAssistant'):
        raise ValueError('Wrong staging identity or service guard missing; no launch')
    executable = app / 'Contents/MacOS/SuiAssistant'
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError('Declared executable missing or not executable; no launch')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)],
                   check=True, capture_output=True, text=True, timeout=8)
    local = root / '.agenda-local'
    local.mkdir(mode=0o700, exist_ok=True)
    folder = local / ('launch-verification-' + str(uuid.uuid4()))
    folder.mkdir(mode=0o700)
    # On the tested Mac, pre-created redirect files caused open to fail -10810.
    # Let open create fresh files inside this private directory, then chmod them.
    stdout, stderr = folder / 'status.json', folder / 'stderr.json'
    started = datetime.datetime.now(datetime.timezone.utc)
    receipt = {'status': 'blocked', 'bundlePath': str(app),
               'startedAt': started.isoformat(), 'timeZone': 'Asia/Shanghai',
               'route': 'macOS open; fixed --agenda status; one attempt',
               'privacyRequest': 'none', 'AppleEntryReads': 'none', 'AppleWrites': 'none',
               'evidenceDirectory': str(folder)}
    try:
        process = subprocess.run(
            ['/usr/bin/open', '-n', '-W', '--stdout', str(stdout), '--stderr',
             str(stderr), str(app), '--args', '--agenda', 'status'],
            capture_output=True, text=True, timeout=12)
        for path in (stdout, stderr):
            if path.exists():
                path.chmod(0o600)
        receipt.update(openExitCode=process.returncode, launcherError=process.stderr)
        if process.returncode != 0:
            raise ValueError('Normal launch failed; no retry or sandbox inference from error alone')
        status = json.loads(stdout.read_text())
        checked = datetime.datetime.fromisoformat(status['checkedAt'].replace('Z', '+00:00'))
        if (status.get('bundleID') != 'local.codex.quota-bar'
                or status.get('bundlePath') != str(app)
                or status.get('privacyRequest') != 'not requested by this status query'
                or status.get('AppleWrites') != 'none'
                or checked < started - datetime.timedelta(seconds=2)
                or checked > datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=2)
                or stderr.read_text().strip()):
            raise ValueError('Missing or inconsistent fresh app readback; launch not verified')
        receipt.update(status='verified', appReadback=status)
    except subprocess.TimeoutExpired:
        receipt.update(status='unknown', reason='12s launch wait timed out; no retry; app has a 60s exit watchdog')
    except (ValueError, KeyError) as error:
        receipt['reason'] = str(error)
    receipt['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    path = folder / 'receipt.json'
    with path.open('x') as handle:
        os.chmod(handle.fileno(), 0o600)
        json.dump(receipt, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    print(json.dumps(receipt, ensure_ascii=False, indent=2))
    return 0 if receipt['status'] == 'verified' else 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'blocked', 'reason': str(error), 'retry': 'none'}))
        sys.exit(2)
