#!/bin/bash
# Sourced after toolchain flags are initialized. Preserve vendored sources intact.
agent_hud_root="$task_root/Vendor/AgentHUDOpen/Sources"
agent_hud_key="$(python3 - "$agent_hud_root" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1]); digest = hashlib.sha256()
for file in sorted(root.rglob('*.swift')):
    digest.update(str(file.relative_to(root)).encode()); digest.update(file.read_bytes())
print(digest.hexdigest())
PY
)-$target_arch"
if [[ ! -f "$build_dir/agent-hud.key" || "$(cat "$build_dir/agent-hud.key")" != "$agent_hud_key" ]]; then
    support_sources=(); core_sources=()
    while IFS= read -r file; do support_sources+=("$file"); done < <(rg --files "$agent_hud_root/AgentHUDSupport" | sort)
    while IFS= read -r file; do core_sources+=("$file"); done < <(rg --files "$agent_hud_root/AgentHUDCore" | sort)
    xcrun swiftc "${swift_flags[@]}" -swift-version 6 -O -whole-module-optimization -parse-as-library -emit-module -emit-library -static \
        -module-name AgentHUDSupport "${support_sources[@]}" \
        -emit-module-path "$build_dir/AgentHUDSupport.swiftmodule" -o "$build_dir/libAgentHUDSupport.a"
    xcrun swiftc "${swift_flags[@]}" -swift-version 6 -O -whole-module-optimization -package-name AgentHUDOpen -parse-as-library -emit-module -emit-library -static \
        -I "$build_dir" -L "$build_dir" -lAgentHUDSupport -module-name AgentHUDCore "${core_sources[@]}" \
        -emit-module-path "$build_dir/AgentHUDCore.swiftmodule" -o "$build_dir/libAgentHUDCore.a"
    printf '%s' "$agent_hud_key" > "$build_dir/agent-hud.key"
fi
agent_hud_flags=(-I "$build_dir" -L "$build_dir" -lAgentHUDCore -lAgentHUDSupport)
