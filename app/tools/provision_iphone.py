"""One-time debug Keychain bootstrap; secret supplied via a file, never argv."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--key-file", type=Path, required=True)
parser.add_argument("--device", required=True)
parser.add_argument("--bundle-id", required=True)
parser.add_argument("--result", type=Path, required=True)
parser.add_argument("--background", action="store_true", help="Launch without bringing the app to the foreground")
args = parser.parse_args()
secret = args.key_file.read_text().strip()
if not secret or "\n" in secret or "\r" in secret:
    raise SystemExit("Invalid key file")
launch_environment = os.environ.copy()
launch_environment["DEVICECTL_CHILD_FALLAPP_MODAL_API_KEY"] = secret
command = ["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
    "--terminate-existing", "--json-output", str(args.result)]
if args.background:
    command.append("--no-activate")
command.append(args.bundle_id)
result = subprocess.run(command, env=launch_environment,
    capture_output=True, text=True)
if args.result.exists():
    args.result.write_text(args.result.read_text().replace(secret, "[REDACTED]"))
    args.result.chmod(0o600)
print(result.stdout.replace(secret, "[REDACTED]"))
if result.returncode:
    print(result.stderr.replace(secret, "[REDACTED]"))
    raise SystemExit(result.returncode)
value = json.loads(args.result.read_text())
if value.get("info", {}).get("outcome") != "success":
    raise SystemExit("Device launch was not successful")
print("Credential provisioned via debug launch environment; verify server status on device.")
