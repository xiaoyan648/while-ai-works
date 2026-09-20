#!/bin/bash
# Sourced by build.sh/check.sh. All compatibility files stay inside this project.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
target_arch="${TARGET_ARCH:-$(uname -m)}"
case "$target_arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $target_arch" >&2; exit 1 ;; esac
build_dir="$task_root/.build/native"
if [[ "$target_arch" != "$(uname -m)" ]]; then build_dir="$task_root/.build/$target_arch"; fi
mkdir -p "$build_dir" .build/compat
swift_flags=(-swift-version 5 -target "$target_arch-apple-macosx14.0")
developer_root="$(xcode-select -p)"
include_root="$developer_root/usr/include/swift"
if [[ -f "$include_root/module.modulemap" && -f "$include_root/bridging.modulemap" ]] && \
   /usr/bin/grep -q 'module SwiftBridging' "$include_root/module.modulemap" && \
   /usr/bin/grep -q 'module SwiftBridging' "$include_root/bridging.modulemap"; then
    printf '// Duplicate SwiftBridging definition omitted for this build.\n' > .build/compat/empty.modulemap
    /usr/bin/python3 - "$include_root/module.modulemap" "$task_root/.build/compat" <<'PY'
import json, pathlib, sys
directory = pathlib.Path(sys.argv[2])
overlay = {'version': 0, 'roots': [{'type': 'file', 'name': sys.argv[1],
    'external-contents': str(directory / 'empty.modulemap')}]}
(directory / 'overlay.json').write_text(json.dumps(overlay))
PY
    swift_flags+=(-vfsoverlay "$task_root/.build/compat/overlay.json" -module-cache-path "$task_root/.build/ModuleCache")
fi
