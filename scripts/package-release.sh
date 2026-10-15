#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$task_root/dist/While AI Works.app}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")
architecture=$(lipo -archs "$app_path/Contents/MacOS/WhileAIWorks")
if [[ "$architecture" != "arm64" && "$architecture" != "x86_64" ]]; then
    echo "Unsupported release architecture: $architecture" >&2
    exit 1
fi
helper_architecture=$(lipo -archs "$app_path/Contents/Resources/while-ai-works-hook")
if [[ "$helper_architecture" != "$architecture" ]]; then
    echo "Application and hook helper architectures differ" >&2; exit 1
fi
interaction_architecture=$(lipo -archs "$app_path/Contents/Resources/while-ai-works-agent-interaction")
if [[ "$interaction_architecture" != "$architecture" ]]; then
    echo "Application and interaction helper architectures differ" >&2; exit 1
fi
codesign --verify --deep --strict "$app_path"
release_dir="$task_root/dist/releases/$version"
mkdir -p "$release_dir"
filename="While-AI-Works-$version-macOS-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_dir/$filename"
unzip -tq "$release_dir/$filename"

# A read-only installer image: drag the app onto the Applications shortcut.
mkdir -p "$task_root/.build"
staging=$(mktemp -d "$task_root/.build/dmg-$architecture.XXXXXX")
mount_point=$(mktemp -d "$task_root/.build/dmg-check-$architecture.XXXXXX")
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then hdiutil detach "$mount_point" >/dev/null || return; fi
    rm -rf "$staging" "$mount_point"
}
trap cleanup EXIT
ditto "$app_path" "$staging/While AI Works.app"
ln -s /Applications "$staging/Applications"
cat > "$staging/安装说明.txt" <<'INSTALL'
将 While AI Works.app 拖到 Applications（应用程序）即可安装。
升级前请先退出旧版应用，再替换；原有设置和鱼获会保留。

需要 macOS 14 或更新版本，请选择与你的 Mac 芯片匹配的安装包。
应用使用 ad-hoc 签名，尚无 Developer ID 签名或 Apple 公证。
首次打开若被系统拦住，请在确认下载来源后，按 macOS「隐私与安全性」提示操作。

项目与安装说明：https://github.com/xiaoyan648/while-ai-works
INSTALL
dmg_name="While-AI-Works-$version-macOS-$architecture.dmg"
hdiutil create -volname "While AI Works $version" -srcfolder "$staging" -format UDZO -ov "$release_dir/$dmg_name"
hdiutil verify "$release_dir/$dmg_name"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$release_dir/$dmg_name" >/dev/null
mounted=true
[[ -L "$mount_point/Applications" && "$(readlink "$mount_point/Applications")" == /Applications ]]
diff -qr "$app_path" "$mount_point/While AI Works.app"
codesign --verify --deep --strict "$mount_point/While AI Works.app"
hdiutil detach "$mount_point" >/dev/null
mounted=false
(cd "$release_dir" && LC_ALL=C LANG=C shasum -a 256 While-AI-Works-"$version"-macOS-*.zip While-AI-Works-"$version"-macOS-*.dmg > SHA256SUMS.txt)
printf 'Release packages:\n%s\n%s\n' "$release_dir/$dmg_name" "$release_dir/$filename"
