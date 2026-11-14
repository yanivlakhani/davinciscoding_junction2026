#!/usr/bin/env python3
"""Copy FallApp diagnostics, excluding media, and generate a latency report."""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path, PurePosixPath
from assess_capture_latency import assess

DEVICE = None
BUNDLE = 'org.local.fallapp.development'
UUID = r'[A-Fa-f0-9-]{36}'
ALLOWED = re.compile(r'(?:sessions/' + UUID + r'/(?:motion|ordered-motion|events|latency)\.jsonl|sessions/' + UUID + r'/(?:session|session-end|rule-configuration)\.json|camera-streams/' + UUID + r'/timeline\.jsonl|captures/' + UUID + r'-[0-9]+/(?:trigger|timing|buffer|capture|attempt-[0-9]+-error)\.json|(?:delivered|outbox|server-responses)/' + UUID + r'-[0-9]+\.json|server-status\.json|network\.jsonl)\Z')

def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='iPhone identifier from xcrun devicectl list devices')
    parser.add_argument('--bundle', default=BUNDLE)
    parser.add_argument('--all-sessions', action='store_true', help='Copy logs from all sessions, not just the latest')
    parser.add_argument('--tail', type=int, default=0, help='Print this many recent lines from each sensor and camera log')
    args = parser.parse_args()
    common = ['--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle]
    with tempfile.TemporaryDirectory() as tmp:
        listing = str(Path(tmp) / 'files.json')
        run(['xcrun', 'devicectl', 'device', 'info', 'files', *common, '--subdirectory', 'Documents/FallApp', '--recurse', '--quiet', '--json-output', listing])
        files = json.loads(Path(listing).read_text())['result']['files']
    sessions = [f for f in files if re.fullmatch(r'sessions/' + UUID + r'/session\.json', f.get('relativePath', ''))]
    if not sessions:
        raise RuntimeError('No monitoring sessions found. Open the app and connect the glasses first.')
    sessions.sort(key=lambda f: f.get('metadata', {}).get('lastModDate', ''))
    ids = {PurePosixPath(f['relativePath']).parts[1] for f in (sessions if args.all_sessions else sessions[-1:])}
    selected = []
    for item in files:
        name = item.get('relativePath', '')
        if not ALLOWED.fullmatch(name) or item.get('resources', {}).get('isDirectory'):
            continue
        parts = PurePosixPath(name).parts
        if parts[0] == 'sessions' and parts[1] not in ids:
            continue
        if parts[0] in ('captures', 'delivered', 'outbox', 'server-responses') and not any(parts[1].startswith(i + '-') for i in ids):
            continue
        selected.append(name)
    output = Path(__file__).resolve().parents[1] / 'data' / 'latency-assessments' / datetime.now().strftime('%Y%m%d-%H%M%S-%f-phone-logs')
    output.mkdir(parents=True)
    failures = []
    for index, name in enumerate(selected, 1):
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        print(f'[{index}/{len(selected)}] {name}', flush=True)
        try:
            run(['xcrun', 'devicectl', 'device', 'copy', 'from', *common, '--source', 'Documents/FallApp/' + name, '--destination', str(target), '--quiet'])
        except subprocess.CalledProcessError as error:
            failures.append(name)
            print('Copy failed:', name, error.stderr.strip(), file=sys.stderr)
    (output / 'retrieval.json').write_text(json.dumps({'sessions': sorted(ids), 'files': selected, 'failed': failures}, indent=2) + '\n')
    print('\nLogs saved:', output)
    if args.tail > 0:
        from collections import deque
        logs = list((output / 'sessions').glob('*/motion.jsonl')) + list((output / 'camera-streams').glob('*/timeline.jsonl'))
        for log in sorted(logs):
            print(f'\n--- {log.relative_to(output)} ---')
            with log.open() as stream:
                for line in deque(stream, maxlen=args.tail):
                    print(line, end='')
        if not logs:
            print('No sensor or camera logs found in this snapshot.')
    try:
        report = assess(output)
        (output / 'latency.json').write_text(json.dumps(report, indent=2) + '\n')
        for session in report['sessions']:
            gaps = session.get('motion_callback_gap_ms') or {}
            compute = session.get('detector_compute_ms') or {}
            print('Session:', session['session_id'], '| profile:', session.get('profile', {}))
            if gaps: print(f"Motion gaps: median {gaps['p50']:.1f} ms, max {gaps['max']:.1f} ms")
            if compute: print(f"Detector computation: median {compute['p50']:.3f} ms")
            if not session.get('session_end'): print('Session still active: snapshot may be incomplete.')
        for capture in report['captures']:
            print('Capture:', capture['event_id'], '| complete:', capture['complete'], '| red to next frame (ms):', capture['red_to_next_live_frame_ms'])
        print('Detailed report:', output / 'latency.json')
    except (ValueError, KeyError, OSError) as error:
        print('Could not analyze snapshot:', error, file=sys.stderr)
        print('Disconnect in the app, then run the script again.', file=sys.stderr)
        return 1
    return 1 if failures else 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
        print('Error:', error, file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        sys.exit(1)
