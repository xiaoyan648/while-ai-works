#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
# Load the actual built app's resources using existing isolated native checks.
# Original project resources cannot mask missing files in the release bundle.
release_app_path="${RELEASE_APP_PATH:-$task_root/dist/While AI Works.app}"
optional_assets=""
cleanup_optional_assets() {
    if [[ -n "$optional_assets" ]]; then rm -rf "$optional_assets"; fi
}
trap cleanup_optional_assets EXIT
if [[ ! -d "$release_app_path/Contents/Resources/AquariumAssets" ]]; then
    optional_assets=$(mktemp -d "$task_root/.build/release-aquarium.XXXXXX")
    python3 - "$release_app_path/Contents/Resources/AquariumPack.json" "$task_root" "$optional_assets" <<'PYPACK'
import hashlib, json, os, sys, zipfile
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
version = manifest['version']
archive = Path(os.environ.get('AQUARIUM_PACK_ARCHIVE', str(Path(sys.argv[2]) / f'dist/resource-packs/aquarium-v{version}/While-AI-Works-Aquarium-v{version}.zip')))
if not archive.is_file():
    raise SystemExit('Build the optional pack first: python3 scripts/package-aquarium-assets.py')
data = archive.read_bytes()
if len(data) != manifest['archiveBytes'] or hashlib.sha256(data).hexdigest() != manifest['sha256']:
    raise SystemExit('Optional pack does not match the release app manifest')
destination = Path(sys.argv[3])
with zipfile.ZipFile(archive) as packed:
    expected = {'AquariumAssets/' + entry['path'] for entry in manifest['files']}
    if set(packed.namelist()) != expected:
        raise SystemExit('Unexpected optional pack inventory')
    packed.extractall(destination)
for entry in manifest['files']:
    data = (destination / 'AquariumAssets' / entry['path']).read_bytes()
    if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise SystemExit('Optional pack file checksum mismatch: ' + entry['path'])
print('Release renderer checks use the slim app plus its verified optional pack')
PYPACK
fi
checks=("$@")
if [[ ${#checks[@]} -eq 0 ]]; then
    checks=(NativeFishingGuideChecks NativeRiverPresentationChecks NativeAquariumViewerChecks NativeMysteryChecks NativeHabitatChecks)
fi
for name in "${checks[@]}"; do
    test_app="$task_root/.build/release-resource-checks/$name.app"
    mkdir -p "$test_app/Contents/MacOS"
    cp "$build_dir/$name" "$test_app/Contents/MacOS/$name"
    rm -rf "$test_app/Contents/Resources"
    mkdir -p "$test_app/Contents/Resources"
    for resource in "$release_app_path/Contents/Resources/"*; do
        ln -s "$resource" "$test_app/Contents/Resources/"
    done
    if [[ -n "$optional_assets" ]]; then
        ln -s "$optional_assets/AquariumAssets" "$test_app/Contents/Resources/AquariumAssets"
    fi
    python3 - "$test_app" "$name" <<'PYINFO'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1], 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'local.whileaiworks.releasechecks.'+sys.argv[2],
    'CFBundleExecutable':sys.argv[2], 'CFBundlePackageType':'APPL'}))
PYINFO
    "$test_app/Contents/MacOS/$name"
done
