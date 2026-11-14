#!/usr/bin/env python3
"""Poll app-written iPhone logs without restarting the app or attaching a debugger."""
import argparse
import json
import re
import subprocess
import tempfile
import time
from datetime import datetime
from pathlib import Path
from pull_phone_logs import BUNDLE, UUID


def emit(message):
    print(datetime.now().strftime('%H:%M:%S'), message, flush=True)


def complete_rows(data, offset=0):
    """Leave an unfinished last line unread until a later snapshot."""
    if offset > len(data):
        offset = 0
    end = data.rfind(b'\n') + 1
    if end <= offset:
        return [], offset
    rows = [json.loads(line) for line in data[offset:end].splitlines() if line.strip()]
    return rows, end


def copy_snapshot(run, common, name, destination, offset):
    """A failed transfer must never replace the last readable snapshot."""
    candidate = destination.with_name(destination.name + '.incoming')
    try:
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', *common, '--source', 'Documents/FallApp/' + name,
             '--destination', str(candidate), '--quiet'])
        data = candidate.read_bytes()
        if len(data) < offset:
            raise ValueError('Snapshot is shorter than the previously read log; keeping the previous offset')
        rows, end = complete_rows(data, offset)
        candidate.replace(destination)
        return rows, end
    finally:
        candidate.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='iPhone identifier from xcrun devicectl list devices')
    parser.add_argument('--bundle', default=BUNDLE)
    parser.add_argument('--interval', type=float, default=3, help='Seconds between polls (default: 3)')
    parser.add_argument('--raw-sensors', action='store_true', help='Print every newly received motion packet')
    args = parser.parse_args()
    if args.interval < 1:
        parser.error('--interval must be at least 1 second')
    common = ['--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle]
    def run(command):
        return subprocess.run(command, check=True, capture_output=True, text=True, timeout=20)
    offsets, versions = {}, {}
    session = None
    last_receipt = None
    last_source = None
    last_new = time.monotonic()
    last_motion_size = None
    background = 'unknown'
    emit('Watching app + glasses logs. Leave monitoring connected. Ctrl+C stops this watcher only.')
    emit('Polling snapshots; display can lag several seconds. No process launch or debugger is used.')
    with tempfile.TemporaryDirectory(prefix='fallapp-watch-') as tmp:
        root = Path(tmp)
        while True:
            started = time.monotonic()
            try:
                listing = root / 'files.json'
                run(['xcrun', 'devicectl', 'device', 'info', 'files', *common, '--subdirectory', 'Documents/FallApp', '--recurse', '--quiet', '--json-output', str(listing)])
                files = json.loads(listing.read_text())['result']['files']
                sessions = [f for f in files if re.fullmatch(r'sessions/' + UUID + r'/session\.json', f.get('relativePath', ''))]
                if not sessions:
                    emit('No monitoring session yet. Open FallApp and connect glasses.')
                else:
                    latest = max(sessions, key=lambda f: f.get('metadata', {}).get('lastModDate', ''))
                    current = latest['relativePath'].split('/')[1]
                    if current != session:
                        session = current
                        last_receipt = last_source = None
                        background = 'unknown'; last_new = time.monotonic()
                        last_motion_size = None
                        emit('SESSION ' + session)
                    selected = []
                    for item in files:
                        name = item.get('relativePath', '')
                        if name in (f'sessions/{session}/motion.jsonl', f'sessions/{session}/events.jsonl', 'network.jsonl'):
                            selected.append(item)
                        elif re.fullmatch(r'camera-streams/' + UUID + r'/timeline\.jsonl', name) and item.get('metadata', {}).get('lastModDate', '') >= latest.get('metadata', {}).get('lastModDate', ''):
                            selected.append(item)
                    sensor_count = 0
                    gaps = []
                    sensor_read_failed = False
                    motion_item = next((f for f in selected if f['relativePath'].endswith('/motion.jsonl')), None)
                    motion_size = motion_item.get('metadata', {}).get('size') if motion_item else None
                    growth = motion_size - last_motion_size if motion_size is not None and last_motion_size is not None else 0
                    last_motion_size = motion_size
                    # Process lifecycle before samples, so the displayed state is current.
                    selected.sort(key=lambda item: (not item['relativePath'].endswith('events.jsonl'), item['relativePath']))
                    for item in selected:
                        name = item['relativePath']; meta = item.get('metadata', {})
                        version = (meta.get('size'), meta.get('lastModDate'))
                        if versions.get(name) == version:
                            continue
                        if meta.get('size', 0) > 64 * 1024 * 1024:
                            raise RuntimeError('Log exceeds 64 MiB. Start a new monitoring session for this live test.')
                        destination = root / name
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        initial = name not in offsets
                        try:
                            rows, end = copy_snapshot(run, common, name, destination, offsets.get(name, 0))
                        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError) as error:
                            if name.endswith('/motion.jsonl'): sensor_read_failed = True
                            emit(f'LOG ACCESS unavailable: {name}. App activity UNKNOWN from this copy; retrying next poll.')
                            if isinstance(error, subprocess.CalledProcessError): emit(error.stderr.strip()[-300:])
                            continue
                        offsets[name] = end; versions[name] = version
                        if name.endswith('/motion.jsonl'):
                            # On initial attachment show current data, not the whole history.
                            if initial:
                                if rows:
                                    last_receipt = int(rows[-1]['phone_receipt_ns'])
                                    last_source = rows[-1]['timestamp_ns']
                                emit('SENSOR saved baseline loaded; waiting for newly appended samples.')
                                continue
                            for row in rows:
                                receipt = int(row['phone_receipt_ns'])
                                if last_receipt is not None and receipt <= last_receipt:
                                    continue
                                if last_receipt is not None: gaps.append((receipt - last_receipt) / 1e6)
                                last_receipt = receipt; last_source = row['timestamp_ns']
                                sensor_count += 1
                                if args.raw_sensors: emit('SENSOR ' + json.dumps(row, separators=(',', ':')))
                        elif name.endswith('/events.jsonl'):
                            for row in rows:
                                if row.get('kind') == 'phone_lifecycle':
                                    background = 'BACKGROUND' if row.get('backgrounded') else 'FOREGROUND'
                                    if not initial or row == rows[-1]: emit('PHONE ' + background)
                                elif not initial:
                                    emit('DETECTOR ' + json.dumps(row, separators=(',', ':')))
                            if initial: emit('PHONE state from saved lifecycle: ' + background)
                        elif name.startswith('camera-streams/'):
                            label = 'CAMERA saved snapshot ' if initial else 'CAMERA '
                            for row in rows:
                                if row.get('kind') != 'frame': emit(label + json.dumps(row, separators=(',', ':')))
                            frames = [row for row in rows if row.get('kind') == 'frame']
                            if frames: emit(label + f'{len(frames)} frames; last phone receipt ns={frames[-1].get("phoneUptimeNs")}')
                        elif name == 'network.jsonl' and not initial:
                            for row in rows: emit('NETWORK ' + json.dumps(row, separators=(',', ':')))
                    if sensor_count:
                        last_new = time.monotonic()
                        gap = f'; largest receipt gap {max(gaps):.1f} ms' if gaps else ''
                        emit(f'SENSOR {background}: +{sensor_count} samples; source ns={last_source}; phone receipt ns={last_receipt}{gap}')
                    elif sensor_read_failed:
                        emit(f'SENSOR {background}: packet timestamps unavailable over the Mac file service; app stop is NOT established.')
                    else:
                        emit(f'SENSOR {background}: no new copied samples for {time.monotonic() - last_new:.1f}s (delivery, log flushing or copy delay)')
                    if growth > 0:
                        emit(f'PHONE LOG grew by {growth} bytes since last listing (write activity; packet continuity requires timestamps).')
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
                emit('DEVICE LOG ACCESS unavailable; monitoring status UNKNOWN: ' + str(error))
                if isinstance(error, subprocess.CalledProcessError): emit(error.stderr.strip()[-600:])
            time.sleep(max(0, args.interval - (time.monotonic() - started)))


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nWatcher stopped; phone monitoring remains unchanged.')
    except RuntimeError as error:
        raise SystemExit(str(error))
