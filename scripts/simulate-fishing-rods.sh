#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -emit-module -emit-library -static \
    -module-name WhileCore Sources/WhileCore/*.swift \
    -emit-module-path "$build_dir/WhileCore.swiftmodule" -o "$build_dir/libWhileCore.a"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore \
    Tests/FishingRodSimulation.swift -o "$build_dir/FishingRodSimulation"
"$build_dir/FishingRodSimulation" > .build/rod-balance.csv
cat .build/rod-balance.csv
