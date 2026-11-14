#!/usr/bin/env bash
# Generates the SBOM a conventional, manifest-reading tool produces, so it can
# be compared against what the CRACI run records during the build.
#
# Usage: ./supply-chain/baseline-sbom.sh
set -euo pipefail

cd "$(dirname "$0")/.."
out="supply-chain/baseline"
mkdir -p "$out"

# Both npm branches build from their repository root, so the lockfile is at
# the top of the branch rather than in a directory named after it.
sbom_for() {
  local branch=$1
  local work
  work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN

  if ! git show "origin/$branch:package-lock.json" > "$work/package-lock.json" 2>/dev/null; then
    echo "skip  $branch — no package-lock.json on this branch"
    return
  fi
  git show "origin/$branch:package.json" > "$work/package.json"

  ( cd "$work" && npm sbom --sbom-format cyclonedx --package-lock-only ) \
    > "$out/$branch.cyclonedx.json"

  local n
  n=$(python3 -c "import json; print(len(json.load(open('$out/$branch.cyclonedx.json')).get('components',[])))")
  echo "ok    $branch — $n components"
}

echo "Lockfile-derived SBOMs (CycloneDX)"
echo
git fetch --quiet origin glasses-ui mobile-app 2>/dev/null || true
sbom_for glasses-ui
sbom_for mobile-app

# The backend has no manifest to read at all: its dependencies are arguments
# to uv_pip_install() inside fall_server.py. Show what that costs.
echo
echo "Backend"
if [ -f backend/fall_server.py ]; then
  declared=$(python3 - <<'PY'
import ast, pathlib
src = pathlib.Path("backend/fall_server.py").read_text()
deps = [a.value for n in ast.walk(ast.parse(src))
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
        and n.func.attr in ("uv_pip_install", "pip_install")
        for a in n.args
        if isinstance(a, ast.Constant) and isinstance(a.value, str)]
print(len(deps))
PY
)
  echo "ok    backend — 0 components from manifests, $declared declared in source"
else
  echo "skip  backend — not on this branch"
fi


# What the lockfile view misses: packages whose install hooks fetch code from
# somewhere other than the registry. Those downloads are not lockfile entries,
# so they appear in no manifest-derived SBOM.
echo
echo "Build-time fetches not represented as packages"
git show origin/mobile-app:package-lock.json 2>/dev/null | python3 -c "
import json, sys
lock = json.load(sys.stdin)
total = len([k for k in lock.get('packages', {}) if k])
hooks = sorted(
    k.split('node_modules/')[-1]
    for k, v in lock.get('packages', {}).items()
    if k and v.get('hasInstallScript')
)
print(f'  {total} packages in package-lock.json')
for h in hooks:
    print(f'  {h} runs an install script that downloads a browser binary')
print('  that binary is not one of the ' + str(total) + ' packages above')
" || echo "  skip — mobile-app branch not fetched"

echo
echo "Written to $out/"
