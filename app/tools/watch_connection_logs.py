#!/usr/bin/env python3
"""Read FallApp connection diagnostics without relaunching it or attaching a debugger."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--bundle', default='org.local.fallapp.development')
    parser.add_argument('--interval', type=float, default=2)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    if args.interval < 1:
        parser.error('--interval must be at least one second')
    common = ['--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle]
    offset, previous_state = 0, None
    print('Watching connection, Meta callbacks and app audio ownership. Ctrl+C stops only this viewer.', flush=True)

    def copy(name, destination):
        destination.unlink(missing_ok=True)
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', *common,
            '--source', 'Documents/FallApp/' + name, '--destination', str(destination), '--quiet'],
            check=True, capture_output=True, text=True, timeout=15)
        return destination.read_bytes()

    with tempfile.TemporaryDirectory(prefix='fallapp-connection-') as directory:
        root = Path(directory)
        while True:
            try:
                data = copy('connection.jsonl', root / 'connection.jsonl')
                if offset > len(data):
                    offset = 0
                end = data.rfind(b'\n') + 1
                for line in data[offset:end].splitlines():
                    row = json.loads(line)
                    print(f"{row.get('time', '')}  {row.get('event', '')}  {row.get('detail', '')}", flush=True)
                offset = end
                snapshot = json.loads(copy('connection-status.json', root / 'state.json'))
                current = (snapshot.get('connection'), snapshot.get('samples'), snapshot.get('appAudio'), snapshot.get('error'))
                if current != previous_state:
                    print(f"LIVE connection={current[0]} · samples={current[1]} · audio={current[2]} · error={current[3] or 'none'}", flush=True)
                    previous_state = current
            except (subprocess.SubprocessError, OSError, ValueError):
                print('Log transfer unavailable. Check the phone connection/unlock; app monitoring state is unknown.', flush=True)
                if args.once:
                    return 1
            if args.once:
                return 0
            time.sleep(args.interval)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        pass
