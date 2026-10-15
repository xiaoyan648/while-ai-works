#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$task_root/scripts/sparkle.sh"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$task_root/assets/Info.plist")
release_dir="$task_root/dist/releases/$version"
mkdir -p "$task_root/updates" "$task_root/.build"
staging=$(mktemp -d "$task_root/.build/appcast.XXXXXX")
trap 'rm -rf "$staging"' EXIT
for architecture in arm64 x86_64; do
    directory="$staging/$architecture"
    mkdir -p "$directory"
    filename="While-AI-Works-$version-macOS-$architecture.zip"
    ln "$release_dir/$filename" "$directory/$filename"
    cp "$task_root/docs/releases/$version.md" "$directory/${filename%.zip}.md"
    feed="$task_root/updates/appcast-$architecture.xml"
    if [[ -f "$feed" ]]; then cp "$feed" "$directory/appcast-$architecture.xml"; fi
    "$sparkle_root/bin/generate_appcast" --account local.whileaiworks.mac --maximum-deltas 0 \
        --download-url-prefix "https://github.com/xiaoyan648/while-ai-works/releases/download/v$version/" \
        --link "https://github.com/xiaoyan648/while-ai-works/releases/tag/v$version" \
        --embed-release-notes -o "$directory/appcast-$architecture.xml" "$directory"
    "$sparkle_root/bin/sign_update" --account local.whileaiworks.mac --verify "$directory/appcast-$architecture.xml"
    cp "$directory/appcast-$architecture.xml" "$feed"
    cp "$feed" "$release_dir/appcast-$architecture.xml"
done
(cd "$release_dir" && LC_ALL=C LANG=C shasum -a 256 While-AI-Works-"$version"-macOS-*.zip While-AI-Works-"$version"-macOS-*.dmg appcast-*.xml > SHA256SUMS.txt)
