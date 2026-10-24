#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != --no-build ]]; then bash scripts/build.sh; fi
python3 - <<'PY'
import pathlib, plistlib, shutil
source = pathlib.Path('dist/While AI Works.app')
target = pathlib.Path('dist/While AI Works Preview.app')
if target.exists(): shutil.rmtree(target)
shutil.copytree(source, target, symlinks=True)
path = target / 'Contents/Info.plist'
with path.open('rb') as file: info = plistlib.load(file)
info.update(CFBundleIdentifier='local.whileaiworks.hermes-dsh-preview',
            CFBundleName='While AI Works Preview', CFBundleDisplayName='While AI Works Preview',
            CFBundleShortVersionString=info['CFBundleShortVersionString'] + '-preview.1',
            WAWLocalPreview=True, SUEnableAutomaticChecks=False)
with path.open('wb') as file: plistlib.dump(info, file)
PY
codesign --force --deep --sign - "dist/While AI Works Preview.app"
codesign --verify --deep --strict "dist/While AI Works Preview.app"
printf 'Local preview: %s/dist/While AI Works Preview.app\n' "$PWD"
