#!/bin/bash
# Render a contact sheet of every mood and coat on light and dark backgrounds.
# Usage: design/mascot/preview.sh [output.png]
set -euo pipefail
export PATH="$HOME/.rive/bin:$PATH"
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build/contact-sheet.png}"
shots="$here/build/shots"
mkdir -p "$shots"
frames=(
  "idle|--advance=40"
  "blink|--advance=301"
  "watch|--data=mood=watch --advance=90"
  "play|--data=mood=play --advance=45"
  "sleep|--data=mood=sleep --advance=140"
  "celebrate|--data=celebrate=1 --advance=52"
  "pet|--data=pet=1 --advance=60"
  "look|--data=lookX=-1 --data=lookY=0.6 --advance=40"
)
for theme in light dark; do
  bg=$([[ $theme == light ]] && echo E4ECE9 || echo 0F1B20)
  for coat in ink snow; do
    project="$here/build/preview-$theme"
    python3 "$here/build_scene.py" --out "$project" --bg "$bg" >/dev/null
    for entry in "${frames[@]}"; do
      name="${entry%%|*}"; args="${entry#*|}"
      # shellcheck disable=SC2086
      rive "$project" --quiet --screenshot="$shots/$theme-$coat-$name.png" --data=coat=$coat $args >/dev/null 2>&1 || \
        rive "$project" --screenshot="$shots/$theme-$coat-$name.png" --data=coat=$coat $args
    done
  done
done
python3 - "$shots" "$out" <<'PY'
import sys
from pathlib import Path
from PIL import Image, ImageDraw
shots, out = Path(sys.argv[1]), Path(sys.argv[2])
names = ["idle", "blink", "watch", "play", "sleep", "celebrate", "pet", "look"]
rows = [(t, c) for t in ("light", "dark") for c in ("ink", "snow")]
cell = 240
sheet = Image.new("RGB", (cell * len(names), (cell + 18) * len(rows)), (255, 255, 255))
draw = ImageDraw.Draw(sheet)
for r, (theme, coat) in enumerate(rows):
    for c, name in enumerate(names):
        im = Image.open(shots / f"{theme}-{coat}-{name}.png").convert("RGB")
        sheet.paste(im.crop((0, 0, cell, cell)), (c * cell, r * (cell + 18) + 18))
        draw.text((c * cell + 6, r * (cell + 18) + 3), f"{theme} {coat} {name}", fill=(60, 60, 60))
sheet.save(out)
print(out)
PY
