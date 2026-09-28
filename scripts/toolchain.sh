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

# Rive runtime for the menu bar cat: the official binary release, fetched once and checked.
rive_version="6.27.0"
rive_checksum="8f78adedd96e48a17a41ac25610847143d52f0bf1bc15bd916bd03b10ba3070d"
rive_root="$task_root/.build/vendor/RiveRuntime-$rive_version"
rive_frameworks="$rive_root/RiveRuntime.xcframework/macos-arm64_x86_64"
if [[ ! -d "$rive_frameworks/RiveRuntime.framework" ]]; then
    mkdir -p "$rive_root"
    rive_archive="$rive_root/RiveRuntime.xcframework.zip"
    curl -fsSL -o "$rive_archive" "https://github.com/rive-app/rive-ios/releases/download/$rive_version/RiveRuntime.xcframework.zip"
    echo "$rive_checksum  $rive_archive" | shasum -a 256 -c - >/dev/null
    (cd "$rive_root" && unzip -q -o RiveRuntime.xcframework.zip && rm RiveRuntime.xcframework.zip)
fi
# Checks run in place, so they look for the framework where it was unpacked.
rive_flags=(-F "$rive_frameworks" -framework RiveRuntime -Xlinker -rpath -Xlinker "$rive_frameworks")
