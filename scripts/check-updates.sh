#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -parse-as-library "${sparkle_flags[@]}" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Tests/NativeUpdateChecks.swift -o "$build_dir/NativeUpdateChecks"
python3 Tests/SparkleUpdateChecks.py "$task_root" "$build_dir/NativeUpdateChecks" "$sparkle_root"
