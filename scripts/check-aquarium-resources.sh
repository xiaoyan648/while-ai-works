#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
fixture="$(mktemp -d "$task_root/.build/aquarium-download-checks.XXXXXX")"
fixture_server=""
cleanup() {
    if [[ -n "$fixture_server" ]]; then
        kill "$fixture_server" 2>/dev/null || true
        wait "$fixture_server" 2>/dev/null || true
    fi
    rm -rf "$fixture"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixture/key.pem" -out "$fixture/cert.pem" \
    -subj '/CN=localhost' -days 1 >/dev/null 2>&1
python3 Tests/Fixtures/aquarium-download-server.py "$fixture" > "$fixture/server.log" 2>&1 &
fixture_server=$!
xcrun swiftc "${swift_flags[@]}" -g -parse-as-library \
    Sources/WhileAIWorks/AquariumResources.swift Tests/AquariumResourceChecks.swift \
    -o "$fixture/AquariumResourceChecks"
for attempt in {1..50}; do
    [[ -f "$fixture/server-url" ]] && break
    sleep 0.1
done
"$fixture/AquariumResourceChecks" "$fixture" "$@"
