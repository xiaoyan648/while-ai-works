#!/bin/bash
# Transparent stills of the cat for docs and offscreen UI renders.
# Renders each pose on black and on white and recovers alpha from the difference.
# Usage: design/mascot/stills.sh [output-dir]
set -euo pipefail
export PATH="$HOME/.rive/bin:$PATH"
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build/stills}"
work="$here/build/matte"
rm -rf "$work"
mkdir -p "$out" "$work"
poses=(
  "idle|--advance=40"
  "sleep|--data=mood=sleep --advance=140"
  "watch|--data=mood=watch --advance=90"
  "play|--data=mood=play --advance=22"
  "celebrate|--data=celebrate=1 --advance=52"
  "pet|--data=pet=1 --advance=60"
)
for bg in 000000 FFFFFF; do
  python3 "$here/build_scene.py" --out "$work/bg-$bg" --bg "$bg" >/dev/null
done
for coat in ink snow; do
  for entry in "${poses[@]}"; do
    name="${entry%%|*}"; args="${entry#*|}"
    for bg in 000000 FFFFFF; do
      # shellcheck disable=SC2086
      rive "$work/bg-$bg" --quiet --screenshot="$work/$coat-$name-$bg.png" --data=coat=$coat $args >/dev/null 2>&1
    done
  done
done
python3 - "$work" "$out" <<'PY'
import sys
from pathlib import Path
import numpy as np
from PIL import Image
work, out = Path(sys.argv[1]), Path(sys.argv[2])
for black in sorted(work.glob("*-000000.png")):
    white = black.with_name(black.name.replace("-000000", "-FFFFFF"))
    b = np.asarray(Image.open(black).convert("RGB"), dtype=np.float32)[:240, :240]
    w = np.asarray(Image.open(white).convert("RGB"), dtype=np.float32)[:240, :240]
    alpha = np.clip(1 - (w - b).mean(axis=2) / 255, 0, 1)
    color = np.where(alpha[..., None] > 0.004, b / np.maximum(alpha[..., None], 1e-3), 0)
    rgba = np.dstack([np.clip(color, 0, 255), alpha * 255]).astype(np.uint8)
    name = black.name.replace("-000000", "")
    Image.fromarray(rgba, "RGBA").save(out / name)
print(out)
PY
