"""Verify the copied model/configuration without any workspace dependency."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "model-lock.json").read_text())
changed = [name for name, value in manifest["files"].items()
           if not (root / name).is_file()
           or hashlib.sha256((root / name).read_bytes()).hexdigest() != value["sha256"]]
if changed:
    raise SystemExit("Selected model/configuration changed: " + ", ".join(changed))
print(f"{manifest['baselineVersion']}: {len(manifest['files'])} model/configuration files verified")
