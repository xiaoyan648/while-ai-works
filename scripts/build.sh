#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
python3 scripts/package-aquarium-assets.py --check
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -emit-module -emit-library -static \
    -module-name WhileCore Sources/WhileCore/*.swift \
    -emit-module-path "$build_dir/WhileCore.swiftmodule" -o "$build_dir/libWhileCore.a"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" \
    -lWhileCore "${agent_hud_flags[@]}" "${sparkle_flags[@]}" -F "$rive_frameworks" -framework RiveRuntime -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/WhileAIWorks/*.swift -o "$build_dir/WhileAIWorks"
app_path="$task_root/dist/While AI Works.app"
if [[ "$target_arch" != "$(uname -m)" ]]; then app_path="$task_root/dist/$target_arch/While AI Works.app"; fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$build_dir/WhileAIWorks" "$app_path/Contents/MacOS/WhileAIWorks"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" \
    -lWhileCore scripts/WorkHook.swift -o "$app_path/Contents/Resources/while-ai-works-hook"
codesign --force --sign - "$app_path/Contents/Resources/while-ai-works-hook"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library "${agent_hud_flags[@]}" \
    scripts/AgentInteractionHook.swift Sources/WhileAIWorks/AgentInteractionJSON.swift -o "$app_path/Contents/Resources/while-ai-works-agent-interaction"
codesign --force --sign - "$app_path/Contents/Resources/while-ai-works-agent-interaction"
cp assets/Info.plist "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set SUFeedURL https://github.com/xiaoyan648/while-ai-works/releases/latest/download/appcast-$target_arch.xml" "$app_path/Contents/Info.plist"
cp -R Sources/WhileAIWorks/Resources/FishAssets "$app_path/Contents/Resources/"
# Remove assets left by older incremental builds; aquarium data is downloaded on demand.
rm -rf "$app_path/Contents/Resources/AquariumAssets"
cp Sources/WhileAIWorks/Resources/AquariumPack.json "$app_path/Contents/Resources/"
python3 - "$app_path/Contents/Resources/LocalAgents" <<'PYRESOURCES'
import pathlib, shutil, sys
path = pathlib.Path(sys.argv[1])
if path.exists(): shutil.rmtree(path)
shutil.copytree('Sources/WhileAIWorks/Resources/LocalAgents', path,
                ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '*.pyo'))
PYRESOURCES
cp -R Sources/WhileAIWorks/Resources/AgentMarks "$app_path/Contents/Resources/"
cp -R Sources/WhileAIWorks/Resources/Rive "$app_path/Contents/Resources/"
cp -R Sources/WhileAIWorks/Resources/Licenses "$app_path/Contents/Resources/"
cp Vendor/AgentHUDOpen/LICENSE "$app_path/Contents/Resources/Licenses/AgentHUDOpen-APACHE-2.0.txt"
mkdir -p "$app_path/Contents/Frameworks"
rm -rf "$app_path/Contents/Frameworks/RiveRuntime.framework"
ditto "$rive_frameworks/RiveRuntime.framework" "$app_path/Contents/Frameworks/RiveRuntime.framework"
rm -rf "$app_path/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_root/Sparkle.framework" "$app_path/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_root/LICENSE" "$app_path/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
# River terrain is rendered from geometry; old full-frame paintings are not shipped.
rm -f "$app_path/Contents/Resources/FishAssets/Scenery/river-day.png" \
      "$app_path/Contents/Resources/FishAssets/Scenery/river-night.png"
# Icon generation runs on the build host, even when cross-compiling the app.
xcrun swiftc "${swift_flags[@]}" -target "$(uname -m)-apple-macosx14.0" scripts/MakeIcon.swift -o "$build_dir/MakeIcon"
"$build_dir/MakeIcon" "$build_dir/AppIcon.iconset" "$task_root/assets/AppIcon.png"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_path"
printf '\nBuilt: %s\n' "$app_path"
