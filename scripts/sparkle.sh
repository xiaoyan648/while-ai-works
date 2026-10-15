#!/bin/bash
# Official, pinned universal framework and release tools. Private keys stay in Keychain.
sparkle_version="2.10.0"
sparkle_checksum="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
sparkle_root="$task_root/.build/vendor/Sparkle-$sparkle_version"
if [[ ! -d "$sparkle_root/Sparkle.framework" ]]; then
    mkdir -p "$sparkle_root"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
        -o "$sparkle_root/distribution.tar.xz"
    python3 - "$sparkle_root/distribution.tar.xz" "$sparkle_checksum" <<'PY'
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
assert hashlib.sha256(p.read_bytes()).hexdigest() == sys.argv[2], 'Sparkle download checksum mismatch'
PY
    tar -xJf "$sparkle_root/distribution.tar.xz" -C "$sparkle_root"
fi
sparkle_flags=(-F "$sparkle_root" -framework Sparkle)
