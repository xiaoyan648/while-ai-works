#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -emit-module -emit-library -static \
    -module-name WhileCore Sources/WhileCore/*.swift \
    -emit-module-path "$build_dir/WhileCore.swiftmodule" -o "$build_dir/libWhileCore.a"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" \
    -lWhileCore -F "$rive_frameworks" -framework RiveRuntime -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/WhileAIWorks/*.swift -o "$build_dir/WhileAIWorks"
app_path="$task_root/dist/While AI Works.app"
if [[ "$target_arch" != "$(uname -m)" ]]; then app_path="$task_root/dist/$target_arch/While AI Works.app"; fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$build_dir/WhileAIWorks" "$app_path/Contents/MacOS/WhileAIWorks"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" \
    -lWhileCore scripts/WorkHook.swift -o "$app_path/Contents/Resources/while-ai-works-hook"
codesign --force --sign - "$app_path/Contents/Resources/while-ai-works-hook"
cp assets/Info.plist "$app_path/Contents/Info.plist"
cp -R Sources/WhileAIWorks/Resources/FishAssets "$app_path/Contents/Resources/"
cp -R Sources/WhileAIWorks/Resources/AquariumAssets "$app_path/Contents/Resources/"
cp -R Sources/WhileAIWorks/Resources/Rive "$app_path/Contents/Resources/"
cp -R Sources/WhileAIWorks/Resources/Licenses "$app_path/Contents/Resources/"
mkdir -p "$app_path/Contents/Frameworks"
rm -rf "$app_path/Contents/Frameworks/RiveRuntime.framework"
ditto "$rive_frameworks/RiveRuntime.framework" "$app_path/Contents/Frameworks/RiveRuntime.framework"
# Keep editable JSON in the project; the app uses the validated binary streams.
python3 - "$app_path/Contents/Resources/AquariumAssets" <<'PYASSETS'
import hashlib, json, sys, shutil
from pathlib import Path
root = Path(sys.argv[1])
for metadata in root.rglob('*.meta.json'):
    stem = metadata.name.removesuffix('.meta.json')
    source = metadata.with_name(stem + '.json')
    binary = metadata.with_name(stem + '.meshbin')
    info = json.loads(metadata.read_text())
    if not binary.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != info['_sourceSHA256']:
        raise SystemExit('Repack stale mesh before building: ' + str(metadata))
    source.unlink()
# River terrain is rendered from geometry; old full-frame paintings are not shipped.
for name in ('river-day.png', 'river-night.png'):
    (root.parent / 'FishAssets' / 'Scenery' / name).unlink(missing_ok=True)
# Picture scenery replaces the unused 3D prop set; editable source assets stay on disk.
shutil.rmtree(root / 'Aquascape', ignore_errors=True)
PYASSETS
# Icon generation runs on the build host, even when cross-compiling the app.
xcrun swiftc "${swift_flags[@]}" -target "$(uname -m)-apple-macosx14.0" scripts/MakeIcon.swift -o "$build_dir/MakeIcon"
"$build_dir/MakeIcon" "$build_dir/AppIcon.iconset" "$task_root/assets/AppIcon.png"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_path"
printf '\nBuilt: %s\n' "$app_path"
