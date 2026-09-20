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
codesign --verify --deep --strict "$app_path"
release_dir="$task_root/dist/releases/$version"
mkdir -p "$release_dir"
filename="While-AI-Works-$version-macOS-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_dir/$filename"
(cd "$release_dir" && LC_ALL=C LANG=C shasum -a 256 While-AI-Works-"$version"-macOS-*.zip > SHA256SUMS.txt)
unzip -tq "$release_dir/$filename"
printf 'Release package: %s\n' "$release_dir/$filename"
