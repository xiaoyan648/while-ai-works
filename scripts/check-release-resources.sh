#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
# Load the actual built app's resources using existing isolated native checks.
# Original project resources cannot mask missing files in the release bundle.
release_app_path="${RELEASE_APP_PATH:-$task_root/dist/While AI Works.app}"
checks=("$@")
if [[ ${#checks[@]} -eq 0 ]]; then
    checks=(NativeFishingGuideChecks NativeRiverPresentationChecks NativeAquariumViewerChecks NativeMysteryChecks NativeHabitatChecks)
fi
for name in "${checks[@]}"; do
    test_app="$task_root/.build/release-resource-checks/$name.app"
    mkdir -p "$test_app/Contents/MacOS"
    cp "$build_dir/$name" "$test_app/Contents/MacOS/$name"
    ln -sfn "$release_app_path/Contents/Resources" "$test_app/Contents/Resources"
    python3 - "$test_app" "$name" <<'PYINFO'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1], 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'local.whileaiworks.releasechecks.'+sys.argv[2],
    'CFBundleExecutable':sys.argv[2], 'CFBundlePackageType':'APPL'}))
PYINFO
    "$test_app/Contents/MacOS/$name"
done
