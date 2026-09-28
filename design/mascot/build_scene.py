#!/usr/bin/env python3
"""Generate scene.rml for the While AI Works spirit cat.

A one-colour cat, ink or snow, whose feelings live in its eyes, with a small
orb of light for company. Authored in plain artboard coordinates (240 x 240,
y down) and written out as RML for the `rive` CLI. Re-run after editing, then build:

    python3 design/mascot/build_scene.py
    rive design/mascot --verify && rive inspect design/mascot --summary
    rive design/mascot --once   # writes design/mascot/build/mascot.riv

View model `Cat` (what the app drives):
    mood       enum  idle | sleep | watch | play
    coat       enum  ink | snow
    lookX      number -1 (left) ... 1 (right)
    lookY      number -1 (up) ... 1 (down)
    celebrate  trigger  star eyes, a hop, a burst of light and a fish made of light
    pet        trigger  happy eyes, a lean and a heart (also fired by clicking the cat)

The look is theme-free: every glow is a light paint that disappears on a light
background and every shadow a dark one that disappears on a dark background, so
the same file works on both.
"""
import argparse
import math
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
W = H = 240
ARGS = argparse.ArgumentParser(description=__doc__.splitlines()[0])
ARGS.add_argument("--out", type=Path, default=HERE, help="project directory to write scene.rml into")
ARGS.add_argument("--bg", help="preview only: paint the artboard with this RRGGBB colour")
ARGS = ARGS.parse_args()


# ---------------------------------------------------------------- ids + xml

class Ids:
    def __init__(self):
        self.n = 10

    def next(self):
        self.n += 1
        return f"0:{self.n}"


IDS = Ids()


def fmt(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        s = f"{v:.4f}".rstrip("0").rstrip(".")
        return "0" if s in ("-0", "") else s
    return str(v)


class El:
    def __init__(self, tag, _id=True, **attrs):
        self.tag = tag
        self.attrs = {k: v for k, v in attrs.items() if v is not None}
        self.children = []
        self.id = IDS.next() if _id else None

    def add(self, *children):
        self.children.extend(children)
        return self

    def render(self, depth=0):
        pad = "    " * depth
        attrs = "".join(f' {k}="{fmt(v)}"' for k, v in self.attrs.items())
        if self.id:
            attrs += f' id="{self.id}"'
        if not self.children:
            return f"{pad}<{self.tag}{attrs}/>"
        inner = "\n".join(c.render(depth + 1) for c in self.children)
        return f"{pad}<{self.tag}{attrs}>\n{inner}\n{pad}</{self.tag}>"


class Comment:
    def __init__(self, text):
        self.text = text

    def render(self, depth=0):
        return "    " * depth + f"<!-- {self.text} -->"


# ------------------------------------------------------------ scene graph

class T:
    """A transform component (Node or Shape) positioned in artboard space."""

    def __init__(self, tag, name, ax, ay, parent, **attrs):
        self.ax, self.ay = ax, ay
        px, py = (parent.ax, parent.ay) if parent else (0, 0)
        self.lx, self.ly = ax - px, ay - py
        self.el = El(tag, x=self.lx, y=self.ly, name=name, **attrs)
        if parent:
            parent.el.add(self.el)

    @property
    def id(self):
        return self.el.id


class Root:
    ax = ay = 0

    def __init__(self, el):
        self.el = el


def node(name, ax, ay, parent, **attrs):
    return T("Node", name, ax, ay, parent, **attrs)


def shape(name, ax, ay, parent, **attrs):
    return T("Shape", name, ax, ay, parent, **attrs)


COLORS = {}  # role -> SolidColor elements the coat layer recolours
STOPS = {}   # role -> (GradientStop, alpha) pairs the coat layer recolours


def paint_color(color, role):
    solid = El("SolidColor", colorValue=color, name=role or "Color")
    if role:
        COLORS.setdefault(role, []).append(solid)
    return solid


def fill(s, color, role=None):
    s.el.add(El("Fill", name="Fill").add(paint_color(color, role)))


def radial_fill(s, cx, cy, radius, color, role=None):
    """A soft glow: `color` at the centre fading to transparent at `radius`."""
    x, y = cx - s.ax, cy - s.ay
    inner = El("GradientStop", colorValue=color, position=0.0, name="Centre")
    outer = El("GradientStop", colorValue="00" + color[2:], position=1.0, name="Edge")
    if role:
        STOPS.setdefault(role, []).extend([(inner, None), (outer, "00")])
    s.el.add(El("Fill", name="Glow").add(
        El("RadialGradient", startX=x, startY=y, endX=x + radius, endY=y, name="Gradient").add(inner, outer)))


def stroke(s, color, thickness, role=None, cap="round", join="round", feather=None, trim=None, name="Stroke"):
    """feather: (strength, offsetX, offsetY). trim: (start, end) as fractions of the path."""
    st = El("Stroke", thickness=thickness, cap=cap, join=join, name=name)
    st.add(paint_color(color, role))
    if feather:
        strength, dx, dy = feather
        st.add(El("Feather", strength=strength, offsetX=dx or None, offsetY=dy or None, name="Feather"))
    if trim:
        st.add(El("TrimPath", start=trim[0], end=trim[1], modeValue="sequential", name="Trim"))
    s.el.add(st)


def ellipse(s, cx, cy, w, h, name="Ellipse"):
    e = El("Ellipse", x=cx - s.ax, y=cy - s.ay, width=w, height=h, name=name)
    s.el.add(e)
    return e


def star(s, size, inner=0.34, corner=1.2):
    s.el.add(El("Star", width=size, height=size, points=4, innerRadius=inner, cornerRadius=corner, name="Path"))


# ------------------------------------------------------------ path parsing

TOKEN = re.compile(r"[MLCZmlcz]|-?\d*\.?\d+(?:e-?\d+)?")


def parse(d):
    """SVG subset (M L C Z, absolute) -> list of (anchors, closed)."""
    tokens = TOKEN.findall(d)
    subpaths, anchors, i, cmd = [], None, 0, None

    def num():
        nonlocal i
        v = float(tokens[i])
        i += 1
        return v

    while i < len(tokens):
        t = tokens[i]
        if t.isalpha():
            cmd = t.upper()
            i += 1
            if cmd == "Z":
                if len(anchors) > 1 and math.dist(anchors[0]["p"], anchors[-1]["p"]) < 1e-6:
                    anchors[0]["in"] = anchors[-1]["in"]
                    anchors.pop()
                subpaths.append((anchors, True))
                anchors = None
            continue
        if cmd == "M":
            if anchors:
                subpaths.append((anchors, False))
            anchors = [{"p": (num(), num()), "in": None, "out": None}]
            cmd = "L"
        elif cmd == "L":
            anchors.append({"p": (num(), num()), "in": None, "out": None})
        elif cmd == "C":
            c1, c2, p = (num(), num()), (num(), num()), (num(), num())
            anchors[-1]["out"] = c1
            anchors.append({"p": p, "in": c2, "out": None})
    if anchors:
        subpaths.append((anchors, False))
    return subpaths


def polar(origin, handle):
    if handle is None:
        return 0.0, 0.0
    dx, dy = handle[0] - origin[0], handle[1] - origin[1]
    return math.atan2(dy, dx), math.hypot(dx, dy)


def path(s, d, name="Path", radii=None):
    """Add every subpath of `d` (artboard coordinates) to shape `s`.
    Returns the list of PointsPath elements, each with `.vertices`."""
    made = []
    for n, (anchors, closed) in enumerate(parse(d)):
        pp = El("PointsPath", isClosed=closed, name=name if n == 0 else f"{name} {n + 1}")
        pp.vertices = []
        for k, a in enumerate(anchors):
            x, y = a["p"][0] - s.ax, a["p"][1] - s.ay
            if a["in"] is None and a["out"] is None:
                r = (radii or {}).get(k)
                v = El("StraightVertex", x=x, y=y, radius=r, name="V")
            else:
                ir, idist = polar(a["p"], a["in"])
                orr, odist = polar(a["p"], a["out"])
                v = El("CubicDetachedVertex", x=x, y=y, inRotation=ir, inDistance=idist,
                       outRotation=orr, outDistance=odist, name="V")
            pp.add(v)
            pp.vertices.append(v)
        s.el.add(pp)
        made.append(pp)
    return made


def mirror(d):
    """Mirror a path across the vertical centre line of the artboard."""
    out, expect_x, tokens = [], True, TOKEN.findall(d)
    for t in tokens:
        if t.isalpha():
            out.append(t)
            expect_x = True
            continue
        out.append(fmt(W - float(t)) if expect_x else t)
        expect_x = not expect_x
    return " ".join(out)


def moved(d, dx, dy):
    out, expect_x = [], True
    for t in TOKEN.findall(d):
        if t.isalpha():
            out.append(t)
            expect_x = True
            continue
        out.append(fmt(float(t) + (dx if expect_x else dy)))
        expect_x = not expect_x
    return " ".join(out)


# ------------------------------------------------------------------ colours

PALETTES = {
    # 墨: near-black with a cool mint rim light and glowing mint eyes.
    "ink": {
        "fur": "FF16181D", "rim": "F08AE8D5", "edge": "00203034", "shade": "FF262A31",
        "eye": "FFD9FCF1", "eyeGlow": "B87FE9D2", "pupil": "FF0B1114", "glint": "00FFFFFF",
        "blush": "5CFF8FA8", "star": "FFFFE7A6", "aura": "4A6FDCC6",
    },
    # 雪: warm white with a white glow (reads on dark) and a soft shadow edge (reads on light).
    "snow": {
        "fur": "FFF7F9F9", "rim": "E0E9FFFA", "edge": "52304A52", "shade": "FFE1E7E9",
        "eye": "FF223A4B", "eyeGlow": "00223A4B", "pupil": "FF0A0F15", "glint": "FFFFFFFF",
        "blush": "80FF9DB2", "star": "FFF5C451", "aura": "70FFFFFF",
    },
}
P = PALETTES["ink"]
LIGHT = "7AD9C3"  # the colour of the orb, motes and dreams: mid mint, visible on light and dark


GLOWS = []  # glow twins of the body parts, drawn behind every fur shape


def glow_paints(s, thickness=3.2):
    """A soft shadow edge (shows on light backgrounds) and a rim of light from the top right (shows on dark)."""
    stroke(s, P["edge"], thickness - 0.7, role="edge", feather=(3, 0, 1.8), name="Edge")
    stroke(s, P["rim"], thickness, role="rim", feather=(4.5, 2.4, -2.4), name="Rim")


def part(name, ax, ay, parent, d=None, oval=None, radii=None, **attrs):
    """A body part in fur, plus a glow twin with the same outline. The twins all draw
    behind the fur (see the draw rules at the end of the scene), so light and shadow
    only show around the outside of the whole cat, never where parts overlap.
    Returns the fur shape and both paths."""
    fur = shape(name, ax, ay, parent, **attrs)
    glow = shape(name + " Glow", ax, ay, parent)
    paths = []
    for s in (fur, glow):
        if oval:
            ellipse(s, *oval)
        else:
            paths.append(path(s, d, radii=radii)[0])
    fill(fur, P["fur"], role="fur")
    glow_paints(glow)
    GLOWS.append(glow)
    return fur, paths


# -------------------------------------------------------------------- scene

artboard_style = El("LayoutComponentStyle", name="Artboard Style")
artboard = El("Artboard", width=W, height=H, name="Cat", clip=False)
ART = Root(artboard)

view_model = El("ViewModel", name="Cat")
instance = El("ViewModelInstance", exports=True, name="Default")
state_machine = El("StateMachine", name="Cat")
artboard.attrs.update(defaultStateMachineId=state_machine.id, styleId=artboard_style.id,
                      viewModelId=view_model.id, viewModelInstanceId=instance.id)
artboard.add(artboard_style)
if ARGS.bg:
    artboard.add(El("Fill", name="Preview Background").add(El("SolidColor", colorValue="FF" + ARGS.bg)))

# Everything drawn sits on a stage nudged down to leave headroom for the hop.
# Sibling order is draw order: the first child draws on top.
STAGE_Y = 12
stage = node("Stage", 0, 0, ART)
stage.el.attrs["y"] = STAGE_Y

# --- effects, on top of everything
fx = node("FX", 0, 0, stage)

BURST_C = (120, 84)
burst = node("Burst", *BURST_C, fx, opacity=0.0)
burst_parts = []
for n in range(8):  # fanned over the top half, so none land on the cat
    angle = -math.pi / 2 + (n - 3.5) * 0.52
    dist = 70 if n % 2 == 0 else 54
    target = (BURST_C[0] + math.cos(angle) * dist, BURST_C[1] + math.sin(angle) * dist * 0.8)
    spark = node(f"Spark {n + 1}", *BURST_C, burst)
    sp = shape(f"Spark Shape {n + 1}", *BURST_C, spark)
    star(sp, 13 if n % 2 == 0 else 8, inner=0.3, corner=1)
    stroke(sp, "99F6C85F", 4, feather=(6, 0, 0), name="Glow")
    fill(sp, "FFFFE9AE")
    burst_parts.append((spark, target))

heart_node = node("Heart", 166, 66, fx, opacity=0.0)
heart = shape("Heart Shape", 166, 66, heart_node)
path(heart, moved("M 0 5.5 C -8.5 -0.5 -9.5 -6.5 -5.4 -9 C -2.8 -10.5 -0.4 -9.2 0 -6.6 "
                  "C 0.4 -9.2 2.8 -10.5 5.4 -9 C 9.5 -6.5 8.5 -0.5 0 5.5 Z", 166, 66))
stroke(heart, "88FF8FA8", 5, feather=(6, 0, 0), name="Glow")
fill(heart, "FFFF97AE")

fish_node = node("Fish", 120, 18, fx, opacity=0.0)
fish = shape("Fish Shape", 120, 18, fish_node)
path(fish, moved("M -10 0 C -5.5 -7 5 -8 11.5 0 C 5 8 -5.5 7 -10 0 Z", 120, 18), name="Body")
path(fish, moved("M -8 0 L -16 -6.5 L -15 0 L -16 6.5 Z", 120, 18), name="Tail", radii={1: 1.5, 3: 1.5})
stroke(fish, "AA" + LIGHT, 5, feather=(7, 0, 0), name="Glow")
fill(fish, "FFA6F0DE")
fish_eye = shape("Fish Eye", 126.5, 16.6, fish_node)
ellipse(fish_eye, 126.5, 16.6, 2.6, 2.6)
fill(fish_eye, "FF1D3A38")

zzz = node("Zzz", 0, 0, fx, opacity=0.0)
z_shapes = []
for n, (zx, zy, zs) in enumerate([(158, 72, 7), (170, 57, 9), (184, 40, 11)]):
    z = shape(f"Z {n + 1}", zx, zy, zzz)
    h = zs / 2
    path(z, f"M {zx - h} {zy - h} L {zx + h} {zy - h} L {zx - h} {zy + h} L {zx + h} {zy + h}")
    stroke(z, "88" + LIGHT, 5, feather=(5, 0, 0), name="Glow")
    stroke(z, "FF" + LIGHT, 2)
    z_shapes.append(z)

# --- the orb: placed by the mood, hovering on its own, brightened by the mood
ORB = (64, 96)
orb = node("Orb", *ORB, stage)
orb_bob = node("Orb Bob", *ORB, orb)
orb_glow = node("Orb Glow", *ORB, orb_bob)
orb_core = shape("Orb Core", *ORB, orb_glow)
ellipse(orb_core, *ORB, 8, 8)
stroke(orb_core, "C8" + LIGHT, 7, feather=(9, 0, 0), name="Glow")
fill(orb_core, "FFF6FFFC")
orb_halo = shape("Orb Halo", *ORB, orb_glow)
ellipse(orb_halo, *ORB, 48, 48)
radial_fill(orb_halo, *ORB, 24, "60" + LIGHT)

# --- the cat, pivoting at the middle of its feet
cat = node("Cat", 120, 206, stage)

hit = shape("Hit Area", 120, 130, cat)
ellipse(hit, 120, 130, 130, 180)
fill(hit, "00000000")

# A front paw that only shows when it leaves the body to pat the orb.
paw = node("Paw", 104, 199, cat, opacity=0.0)
part("Paw Shape", 104, 199, paw, oval=(104, 199, 21, 13))

head_bob = node("Head Bob", 120, 126, cat)
head_tilt = node("Head Tilt", 120, 126, head_bob)
head_look = node("Head Look", 120, 126, head_tilt)

EYE_Y = 96
face = node("Face", 120, EYE_Y, head_look)

blush = shape("Blush", 120, 113, face, opacity=0.0)
ellipse(blush, 96, 113, 13, 6.5)
ellipse(blush, 144, 113, 13, 6.5)
fill(blush, P["blush"], role="blush")


def eye_line(name, d, width):
    s = shape(name, 120, EYE_Y, face, opacity=0.0)
    path(s, d)
    path(s, mirror(d), name="Right")
    stroke(s, P["eyeGlow"], width + 3, role="eyeGlow", feather=(5, 0, 0), name="Glow")
    stroke(s, P["eye"], width, role="eye")
    return s


eyes_happy = eye_line("Eyes Happy", "M 92.5 100 C 95.5 90.5 106.5 90.5 109.5 100", 3.8)
eyes_sleep = eye_line("Eyes Sleep", "M 92.5 96 C 96 102 106 102 109.5 96", 3.2)

eyes_star = node("Eyes Star", 120, EYE_Y, face, opacity=0.0)
star_eyes = []
for side, ex in (("L", 101), ("R", 139)):
    st = shape(f"Star Eye {side}", ex, EYE_Y, eyes_star)
    star(st, 25, inner=0.36, corner=1.6)
    stroke(st, "99F6C85F", 5, feather=(6, 0, 0), name="Glow")
    fill(st, P["star"], role="star")
    star_eyes.append(st)

# Open eyes: sized by the mood, darting with the mood, blinking on their own.
eyes = node("Eyes", 120, EYE_Y, face)
eyes_dart = node("Eyes Dart", 120, EYE_Y, eyes)
eyes_blink = node("Eyes Blink", 120, EYE_Y, eyes_dart)
pupils, eye_nodes = {}, {}
for side, ex in (("L", 101), ("R", 139)):
    eye = node(f"Eye {side}", ex, EYE_Y, eyes_blink)
    glint = shape(f"Glint {side}", ex + 3.4, EYE_Y - 5.4, eye)
    ellipse(glint, ex + 3.4, EYE_Y - 5.4, 5, 5)
    fill(glint, P["glint"], role="glint")
    small = shape(f"Glint Small {side}", ex - 3.2, EYE_Y + 5.5, eye)
    ellipse(small, ex - 3.2, EYE_Y + 5.5, 2.4, 2.4)
    fill(small, P["glint"], role="glint")
    pupil_node = node(f"Pupil {side}", ex, EYE_Y, eye, opacity=0.0)
    pupil = shape(f"Pupil Shape {side}", ex, EYE_Y, pupil_node)
    ellipse(pupil, ex, EYE_Y, 4.2, 16)
    fill(pupil, P["pupil"], role="pupil")
    iris = shape(f"Iris {side}", ex, EYE_Y, eye)
    ellipse(iris, ex, EYE_Y, 16, 21)
    stroke(iris, P["eyeGlow"], 5, role="eyeGlow", feather=(7, 0, 0), name="Glow")
    fill(iris, P["eye"], role="eye")
    pupils[side], eye_nodes[side] = pupil_node, eye

HEAD = ("M 120 53 C 146 53 166 68 167 92 C 168 114 148 131 120 131 "
        "C 92 131 72 114 73 92 C 74 68 94 53 120 53 Z")
part("Head", 120, 92, head_look, HEAD)

ears = {}
for side, pivot_x in (("L", 96), ("R", 144)):
    ear = node(f"Ear {side}", pivot_x, 62, head_look)
    d = "M 76 88 L 79 31 L 115 56 Z"
    part(f"Ear Shape {side}", pivot_x, 62, ear, mirror(d) if side == "R" else d, radii={1: 9})
    ears[side] = ear

torso = node("Torso", 120, 206, cat)
paw_line = shape("Paw Line", 120, 196, torso)
path(paw_line, "M 120 187 L 120 204.5")
stroke(paw_line, P["shade"], 2.2, role="shade")
part("Body", 120, 206, torso, "M 92 116 C 73 131 67 172 72 193 C 75 203 84 206 96 206 L 144 206 "
                              "C 156 206 165 203 168 193 C 173 172 167 131 148 116 Z")

# The tail is one path stroked three times, trimmed shorter as it gets thicker, so it tapers.
TAIL = "M 161 198 C 191 203 206 179 200 149 C 196 129 183 117 172 121"
tail = shape("Tail", 161, 198, cat)
tail_glow = shape("Tail Glow", 161, 198, cat)
tail_paths = [path(tail, TAIL)[0], path(tail_glow, TAIL)[0]]
stroke(tail, P["fur"], 7, role="fur", name="Tip")
stroke(tail, P["fur"], 9.5, role="fur", trim=(0.0, 0.72), name="Middle")
stroke(tail, P["fur"], 12, role="fur", trim=(0.0, 0.4), name="Base")
glow_paints(tail_glow, thickness=9.5)
GLOWS.append(tail_glow)
# Every glow twin sits just behind the rearmost fur (the tail), in tree order among themselves.
for g in GLOWS:
    target = El("DrawTarget", drawableId=tail.id, placementValue="after", name="Behind Fur")
    g.el.add(El("DrawRules", drawTargetId=target.id, name="Draw Order").add(target))

# --- ambience behind the cat
motes = node("Motes", 0, 0, stage)
mote_shapes = []
for n, (mx, my, phase) in enumerate([(46, 150, 0), (196, 92, 60), (72, 66, 120), (184, 162, 30),
                                     (30, 104, 160), (210, 128, 100), (152, 34, 180)]):
    m = shape(f"Mote {n + 1}", mx, my, motes, opacity=0.0)
    ellipse(m, mx, my, 3.2, 3.2)
    stroke(m, "B3" + LIGHT, 4, feather=(5, 0, 0), name="Glow")
    fill(m, "FFEFFFF9")
    mote_shapes.append((m, phase))

aura = shape("Aura", 120, 126, stage)
ellipse(aura, 120, 126, 220, 220)
radial_fill(aura, 120, 126, 110, P["aura"], role="aura")

ground = node("Ground", 120, 207, stage)
ground_glow = shape("Ground Glow", 120, 207, ground, scaleY=0.13)
ellipse(ground_glow, 120, 207, 170, 170)
radial_fill(ground_glow, 120, 207, 85, "66" + LIGHT)
shadow = shape("Shadow", 120, 207, ground, scaleY=0.11)
ellipse(shadow, 120, 207, 128, 128)
radial_fill(shadow, 120, 207, 64, "3A1E2A2E")


# ------------------------------------------------------------ view model

mood_enum = El("DataEnumCustom", name="Mood")
MOOD = {}
for key, label in (("idle", "Idle"), ("sleep", "Sleep"), ("watch", "Watch"), ("play", "Play"), ("proud", "Proud"), ("curious", "Curious"), ("effort", "Effort"), ("focus", "Focus")):
    v = El("DataEnumValue", key=key, value=label)
    mood_enum.add(v)
    MOOD[key] = v
coat_enum = El("DataEnumCustom", name="Coat")
COAT = {}
for key, label in (("ink", "Ink"), ("snow", "Snow")):
    v = El("DataEnumValue", key=key, value=label)
    coat_enum.add(v)
    COAT[key] = v

vm_mood = El("ViewModelPropertyEnumCustom", enumId=mood_enum.id, name="mood")
vm_coat = El("ViewModelPropertyEnumCustom", enumId=coat_enum.id, name="coat")
vm_look_x = El("ViewModelPropertyNumber", name="lookX")
vm_look_y = El("ViewModelPropertyNumber", name="lookY")
vm_celebrate = El("ViewModelPropertyTrigger", name="celebrate")
vm_pet = El("ViewModelPropertyTrigger", name="pet")
view_model.attrs["defaultInstanceId"] = instance.id
view_model.add(vm_mood, vm_coat, vm_look_x, vm_look_y, vm_celebrate, vm_pet, instance)
instance.add(
    El("ViewModelInstanceEnum", propertyValue=MOOD["idle"].id, viewModelPropertyId=vm_mood.id),
    El("ViewModelInstanceEnum", propertyValue=COAT["ink"].id, viewModelPropertyId=vm_coat.id),
    El("ViewModelInstanceNumber", propertyValue=0, viewModelPropertyId=vm_look_x.id),
    El("ViewModelInstanceNumber", propertyValue=0, viewModelPropertyId=vm_look_y.id),
    El("ViewModelInstanceTrigger", viewModelPropertyId=vm_celebrate.id),
    El("ViewModelInstanceTrigger", viewModelPropertyId=vm_pet.id),
)


def vm_path(prop):
    return f"{view_model.id}-{prop.id}"


# -------------------------------------------------------------- animation

PROP = {"x": 13, "y": 14, "rotation": 15, "scaleX": 16, "scaleY": 17, "opacity": 18,
        "color": 37, "stop": 38, "vx": 24, "vy": 25}
EASE = {
    "io": (0.42, 0, 0.58, 1),
    "out": (0.22, 1, 0.36, 1),
    "in": (0.55, 0, 1, 0.45),
    "soft": (0.37, 0, 0.63, 1),
    "back": (0.34, 1.56, 0.64, 1),
}


class Anim:
    def __init__(self, name, duration, loop="loop"):
        self.el = El("LinearAnimation", name=name, fps=60, duration=duration, loopValue=loop)
        self.tracks = {}
        self.explicit = set()
        self.duration = duration

    @property
    def id(self):
        return self.el.id

    def key(self, target, prop, frames, posed=False):
        """frames: [(frame, value, ease)] where ease is a key of EASE, 'lin' or 'hold'.
        The ease of a key shapes the segment that starts at it."""
        tid = target.id if hasattr(target, "id") else target
        if posed and (tid, prop) in self.explicit:
            return self
        if not posed:
            self.explicit.add((tid, prop))
        self.tracks.setdefault(tid, {}).setdefault(prop, []).extend(frames)
        return self

    def build(self):
        for tid, props in self.tracks.items():
            ko = El("KeyedObject", objectId=tid)
            for prop, frames in props.items():
                kp = El("KeyedProperty", propertyKey=PROP[prop])
                for f in sorted(frames, key=lambda k: k[0]):
                    frame, value = f[0], f[1]
                    ease = f[2] if len(f) > 2 else "io"
                    if prop in ("color", "stop"):
                        kp.add(El("KeyFrameColor", value=value, frame=frame, interpolationType="linear"))
                        continue
                    if ease in ("lin", "hold"):
                        kp.add(El("KeyFrameDouble", value=float(value), frame=frame,
                                  interpolationType="linear" if ease == "lin" else "hold"))
                    else:
                        x1, y1, x2, y2 = EASE[ease]
                        kp.add(El("KeyFrameDouble", value=float(value), frame=frame, interpolationType="cubic")
                               .add(El("CubicEaseInterpolator", x1=x1, y1=y1, x2=x2, y2=y2)))
                ko.add(kp)
            self.el.add(ko)
        return self.el


def wave(anim, target, prop, base, amp, period, phase=0.0, steps_per_period=12):
    """A sine around `base`, sampled with linear keys across the whole animation."""
    steps = max(4, round(anim.duration / period * steps_per_period))
    frames = sorted({round(anim.duration * i / steps) for i in range(steps + 1)})
    anim.key(target, prop, [(f, base + amp * math.sin(2 * math.pi * f / period + phase), "lin") for f in frames])


def at(target, x, y):
    """Artboard-space point to a local value pair for `target`."""
    return x + target.lx - target.ax, y + target.ly - target.ay


# Everything the mood layer poses, with its resting value. Each mood animation
# keys the full set so that any two moods blend cleanly.
POSE = {
    (eyes, "opacity"): 1.0, (eyes, "scaleX"): 1.0, (eyes, "scaleY"): 1.0,
    (eyes_dart, "x"): eyes_dart.lx, (eyes_dart, "y"): eyes_dart.ly,
    (eyes_happy, "opacity"): 0.0, (eyes_sleep, "opacity"): 0.0, (eyes_star, "opacity"): 0.0,
    (blush, "opacity"): 0.0,
    (ears["L"], "rotation"): 0.0, (ears["R"], "rotation"): 0.0,
    (ears["L"], "y"): ears["L"].ly, (ears["R"], "y"): ears["R"].ly,
    (head_tilt, "rotation"): 0.0, (head_tilt, "y"): head_tilt.ly,
    (cat, "y"): cat.ly, (cat, "scaleX"): 1.0, (cat, "scaleY"): 1.0, (cat, "rotation"): 0.0,
    (ground, "scaleX"): 1.0,
    (orb, "x"): orb.lx, (orb, "y"): orb.ly,
    (orb_glow, "opacity"): 1.0, (orb_glow, "scaleX"): 1.0, (orb_glow, "scaleY"): 1.0,
    (paw, "opacity"): 0.0, (paw, "x"): paw.lx, (paw, "y"): paw.ly, (paw, "rotation"): 0.0,
    (zzz, "opacity"): 0.0, (heart_node, "opacity"): 0.0, (burst, "opacity"): 0.0, (fish_node, "opacity"): 0.0,
    (aura, "opacity"): 1.0,
}
for side in ("L", "R"):
    POSE.update({(pupils[side], "opacity"): 0.0, (pupils[side], "scaleX"): 1.0, (pupils[side], "scaleY"): 1.0})


def pose(anim, frames, overrides):
    """Hold every pose property at `frames`, using overrides where given.
    Call after the explicit keys: properties already animated are left alone."""
    for (target, prop), rest in POSE.items():
        value = overrides.get((target, prop), rest)
        anim.key(target, prop, [(f, value, "io") for f in frames], posed=True)


def orb_path(anim, points):
    """points: [(frame, (x, y) in stage space, ease)]."""
    anim.key(orb, "x", [(f, x - orb.ax + orb.lx, e) for f, (x, _), e in points])
    anim.key(orb, "y", [(f, y - orb.ay + orb.ly, e) for f, (_, y), e in points])


def dart(anim, points):
    """Quick eye movements that then hold: points [(frame, dx, dy)], each move 6 frames long."""
    xs, ys = [], []
    for n, (f, dx, dy) in enumerate(points):
        if n == 0:
            xs.append((f, dx, "hold"))
            ys.append((f, dy, "hold"))
            continue
        xs += [(f - 6, xs[-1][1], "out"), (f, dx, "hold")]
        ys += [(f - 6, ys[-1][1], "out"), (f, dy, "hold")]
    anim.key(eyes_dart, "x", xs)
    anim.key(eyes_dart, "y", ys)


def pat(anim, start, reach=(-40, -45)):
    """The paw leaves the body, pats at `reach` (offset from the feet) and tucks back in."""
    lx, ly = paw.lx, paw.ly
    rx, ry = reach
    anim.key(paw, "opacity", [(start, 0, "lin"), (start + 3, 1, "hold"), (start + 26, 1, "lin"), (start + 30, 0, "hold")])
    anim.key(paw, "x", [(start, lx, "out"), (start + 9, rx + 10, "io"), (start + 14, rx, "out"), (start + 28, lx, "io")])
    anim.key(paw, "y", [(start, ly, "out"), (start + 9, ry + 5, "io"), (start + 14, ry, "out"), (start + 28, ly, "io")])
    anim.key(paw, "rotation", [(start, 0, "out"), (start + 9, -0.5, "io"), (start + 14, -0.85, "out"), (start + 28, 0, "io")])


def with_rest(anim, target, prop, frames):
    """Pad a keyed track with resting keys at both ends of the animation."""
    rest = POSE[(target, prop)]
    anim.key(target, prop, [(0, rest, "hold")] + frames + [(anim.duration, rest, "hold")])


animations = []

# --- always-on layers
breathe = Anim("Breathe", 210)
breathe.key(torso, "scaleY", [(0, 1, "soft"), (105, 1.022, "soft"), (210, 1, "soft")])
breathe.key(head_bob, "y", [(0, head_bob.ly, "soft"), (105, head_bob.ly - 1.8, "soft"), (210, head_bob.ly, "soft")])
animations.append(breathe)

blink = Anim("Blink", 600)
blink_y, blink_x = [(0, 1, "hold")], [(0, 1, "hold")]
for t in (140, 330, 346, 520):  # one of them a double blink
    blink_y += [(t, 1, "in"), (t + 4, 0.06, "out"), (t + 10, 1, "hold")]
    blink_x += [(t, 1, "in"), (t + 4, 1.08, "out"), (t + 10, 1, "hold")]
blink.key(eyes_blink, "scaleY", blink_y + [(600, 1, "hold")])
blink.key(eyes_blink, "scaleX", blink_x + [(600, 1, "hold")])
animations.append(blink)

drift = Anim("Motes", 360)
for m, p in mote_shapes:
    drift.key(m, "opacity", [(0, 0, "hold"), (p, 0, "io"), (p + 50, 0.95, "io"), (p + 120, 0.8, "io"),
                             (p + 170, 0, "hold"), (360, 0, "hold")])
    drift.key(m, "y", [(0, m.ly + 10, "hold"), (p, m.ly + 10, "lin"), (p + 170, m.ly - 22, "hold"), (360, m.ly - 22, "hold")])
    drift.key(m, "x", [(0, m.lx, "hold"), (p, m.lx, "soft"), (p + 85, m.lx + 5, "soft"), (p + 170, m.lx, "hold"),
                       (360, m.lx, "hold")])
animations.append(drift)

hover = Anim("Orb Hover", 240)
wave(hover, orb_bob, "y", orb_bob.ly, 3.5, 120)
wave(hover, orb_bob, "x", orb_bob.lx, 2.0, 240, phase=math.pi / 2)
animations.append(hover)

# The tail sways as a wave: the base leads, the middle and tip follow late and wider.
def sway(anim, period, turn, bias, mid_amp, tip_amp, lag):
    for s in (tail, tail_glow):
        wave(anim, s, "rotation", bias, turn, period)
    for tail_path in tail_paths:
        for vertex, (ax, ay), phase in ((tail_path.vertices[1], mid_amp, -lag), (tail_path.vertices[2], tip_amp, -2 * lag)):
            wave(anim, vertex, "vx", float(vertex.attrs["x"]), ax, period, phase=phase)
            wave(anim, vertex, "vy", float(vertex.attrs["y"]), ay, period, phase=phase)


tail_slow = Anim("Tail Slow", 240)
sway(tail_slow, 240, turn=0.05, bias=0.01, mid_amp=(2.5, 1.5), tip_amp=(5.5, 3.0), lag=0.85)
animations.append(tail_slow)

tail_fast = Anim("Tail Fast", 84)
sway(tail_fast, 84, turn=0.09, bias=0.02, mid_amp=(3.5, 2.0), tip_amp=(8.0, 4.5), lag=0.95)
animations.append(tail_fast)

# Joystick timelines: frame 0 is left / up, the middle frame is centred. Turning the
# head moves the face more than the outline and the ears the other way, and the far
# eye narrows a little, so the flat cat reads as round.
look_x = Anim("Look X", 60, loop="oneShot")
look_y = Anim("Look Y", 60, loop="oneShot")
look_x.key(face, "x", [(0, face.lx - 4.5, "lin"), (60, face.lx + 4.5, "lin")])
look_x.key(head_look, "x", [(0, head_look.lx - 2, "lin"), (60, head_look.lx + 2, "lin")])
look_x.key(head_look, "rotation", [(0, -0.05, "lin"), (60, 0.05, "lin")])
for side in ("L", "R"):
    e = ears[side]
    look_x.key(e, "x", [(0, e.lx + 1.8, "lin"), (60, e.lx - 1.8, "lin")])
    look_y.key(e, "y", [(0, e.ly + 1.2, "lin"), (60, e.ly - 1.2, "lin")])
look_x.key(eye_nodes["L"], "scaleX", [(0, 0.86, "lin"), (30, 1, "lin"), (60, 1, "lin")])
look_x.key(eye_nodes["R"], "scaleX", [(0, 1, "lin"), (30, 1, "lin"), (60, 0.86, "lin")])
look_y.key(face, "y", [(0, face.ly - 3.5, "lin"), (60, face.ly + 3, "lin")])
look_y.key(head_look, "y", [(0, head_look.ly - 1.5, "lin"), (60, head_look.ly + 1.5, "lin")])
animations += [look_x, look_y]

# --- moods

# Idle: the orb drifts over the head and round the right; the eyes follow it in
# quick glances; when it dips low on the left the cat pats it away.
idle = Anim("Idle", 480)
orb_path(idle, [(0, (64, 96), "soft"), (110, (84, 42), "soft"), (230, (166, 38), "soft"), (300, (192, 98), "soft"),
                (374, (84, 158), "out"), (404, (40, 112), "soft"), (480, (64, 96), "soft")])
dart(idle, [(0, -1.8, -1.2), (110, 0, -2.4), (230, 2.2, -1.8), (302, 2.6, 0.4), (362, -2.4, 2.2),
            (404, -2.2, -0.4), (480, -1.8, -1.2)])
idle.key(head_tilt, "rotation", [(0, -0.035, "soft"), (110, -0.01, "soft"), (230, 0.045, "soft"), (300, 0.05, "soft"),
                                 (362, -0.06, "soft"), (404, -0.05, "soft"), (480, -0.035, "soft")])
pat(idle, 360)
idle.key(orb_glow, "scaleX", [(0, 1, "hold"), (372, 1, "out"), (377, 1.4, "io"), (392, 1, "hold"), (480, 1, "hold")])
idle.key(orb_glow, "scaleY", [(0, 1, "hold"), (372, 1, "out"), (377, 1.4, "io"), (392, 1, "hold"), (480, 1, "hold")])
with_rest(idle, ears["R"], "rotation", [(250, 0, "out"), (254, 0.2, "io"), (259, -0.05, "io"), (265, 0, "io")])
with_rest(idle, ears["L"], "rotation", [(432, 0, "out"), (436, -0.16, "io"), (442, 0, "io")])
pose(idle, [0, 480], {})
animations.append(idle)

# Sleep: eyes shut, head down, ears soft; the orb rests low and dims; dreams rise.
sleep_over = {
    (eyes, "opacity"): 0.0, (eyes_sleep, "opacity"): 1.0, (head_tilt, "rotation"): 0.07,
    (head_tilt, "y"): head_tilt.ly + 5, (ears["L"], "rotation"): -0.14, (ears["R"], "rotation"): 0.14,
    (ears["L"], "y"): ears["L"].ly + 2, (ears["R"], "y"): ears["R"].ly + 2,
    (orb_glow, "scaleX"): 0.8, (orb_glow, "scaleY"): 0.8, (aura, "opacity"): 0.6, (zzz, "opacity"): 1.0,
}
sleep = Anim("Sleep", 240)
orb_path(sleep, [(0, (56, 190), "hold"), (240, (56, 190), "hold")])
wave(sleep, orb_glow, "opacity", 0.45, 0.12, 240)
for n, z in enumerate(z_shapes):
    start = n * 36
    sleep.key(z, "opacity", [(0, 0, "hold"), (start, 0, "io"), (start + 26, 1, "io"),
                             (start + 84, 1, "io"), (start + 124, 0, "hold"), (240, 0, "hold")])
    sleep.key(z, "y", [(0, z.ly + 6, "hold"), (start, z.ly + 6, "soft"), (start + 124, z.ly - 7, "hold"),
                       (240, z.ly - 7, "hold")])
pose(sleep, [0, 240], sleep_over)
animations.append(sleep)

# Watch: eyes wide with slit pupils, ears forward; now and then the pupils flare
# as if something bit. The orb hangs quietly like a lantern.
watch_over = {
    (eyes, "scaleX"): 1.1, (eyes, "scaleY"): 1.1, (eyes_dart, "y"): eyes_dart.ly + 1.5,
    (pupils["L"], "opacity"): 1.0, (pupils["R"], "opacity"): 1.0,
    (ears["L"], "rotation"): 0.08, (ears["R"], "rotation"): -0.08,
    (ears["L"], "y"): ears["L"].ly - 3, (ears["R"], "y"): ears["R"].ly - 3,
    (head_tilt, "y"): head_tilt.ly + 1.5, (orb_glow, "opacity"): 0.85,
}
watch = Anim("Watch", 300)
orb_path(watch, [(0, (52, 66), "hold"), (300, (52, 66), "hold")])
watch.key(head_tilt, "rotation", [(0, 0, "soft"), (60, 0, "soft"), (140, 0.035, "soft"), (220, -0.02, "soft"),
                                  (300, 0, "soft")])
for side in ("L", "R"):
    p = pupils[side]
    watch.key(p, "scaleX", [(0, 1, "hold"), (170, 1, "out"), (176, 2.3, "io"), (222, 2.3, "io"), (236, 1, "hold"),
                            (300, 1, "hold")])
watch.key(ears["L"], "rotation", [(0, 0.08, "hold"), (172, 0.08, "out"), (176, 0.16, "io"), (184, 0.08, "hold"),
                                  (300, 0.08, "hold")])
watch.key(ears["R"], "rotation", [(0, -0.08, "hold"), (172, -0.08, "out"), (176, -0.16, "io"), (184, -0.08, "hold"),
                                  (300, -0.08, "hold")])
pose(watch, [0, 300], watch_over)
animations.append(watch)

# Play: the orb bounces into reach twice a loop and gets batted back up; big
# bright eyes and the head follow it.
play_over = dict(watch_over)
play_over.update({(eyes, "scaleX"): 1.1, (eyes, "scaleY"): 1.1, (orb_glow, "opacity"): 1.0,
                  (pupils["L"], "opacity"): 0.0, (pupils["R"], "opacity"): 0.0,
                  (ears["L"], "rotation"): 0.06, (ears["R"], "rotation"): -0.06})
play = Anim("Play", 120)
orb_path(play, [(0, (52, 92), "in"), (24, (84, 158), "out"), (56, (44, 64), "in"), (84, (84, 158), "out"),
                (120, (52, 92), "in")])
pat(play, 10)
pat(play, 70)
play.key(head_tilt, "rotation", [(0, -0.05, "soft"), (24, -0.09, "soft"), (56, -0.06, "soft"), (84, -0.09, "soft"),
                                 (120, -0.05, "soft")])
play.key(eyes_dart, "x", [(0, -2.0, "soft"), (24, -2.6, "soft"), (56, -2.4, "soft"), (84, -2.6, "soft"), (120, -2.0, "soft")])
play.key(eyes_dart, "y", [(0, -0.5, "soft"), (24, 2.2, "soft"), (56, -2.2, "soft"), (84, 2.2, "soft"), (120, -0.5, "soft")])
for f in (24, 84):
    play.key(orb_glow, "scaleX", [(f - 2, 1, "out"), (f + 3, 1.35, "io"), (f + 16, 1, "io")])
    play.key(orb_glow, "scaleY", [(f - 2, 1, "out"), (f + 3, 1.35, "io"), (f + 16, 1, "io")])
pose(play, [0, 120], play_over)
animations.append(play)

# Celebrate: crouch, hop with star eyes, a burst of light and a fish of light
# overhead while the orb circles.
celebrate = Anim("Celebrate", 90, loop="oneShot")
star_face = {(eyes, "opacity"): 0.0, (eyes_star, "opacity"): 1.0, (blush, "opacity"): 1.0}
celebrate.key(cat, "y", [(0, cat.ly, "io"), (8, cat.ly, "out"), (24, cat.ly - 26, "io"), (34, cat.ly - 29, "in"),
                         (48, cat.ly, "out"), (90, cat.ly, "io")])
celebrate.key(cat, "scaleY", [(0, 1, "io"), (8, 0.9, "out"), (22, 1.07, "io"), (34, 1, "in"), (48, 0.91, "out"),
                              (60, 1.03, "io"), (70, 1, "io"), (90, 1, "io")])
celebrate.key(cat, "scaleX", [(0, 1, "io"), (8, 1.07, "out"), (22, 0.95, "io"), (34, 1, "in"), (48, 1.07, "out"),
                              (60, 0.98, "io"), (70, 1, "io"), (90, 1, "io")])
celebrate.key(ground, "scaleX", [(0, 1, "io"), (8, 1.05, "out"), (28, 0.66, "io"), (40, 0.68, "in"), (48, 1.05, "io"),
                                 (90, 1, "io")])
celebrate.key(ears["L"], "rotation", [(8, 0, "out"), (24, 0.14, "io"), (48, -0.08, "io"), (64, 0, "io")])
celebrate.key(ears["R"], "rotation", [(8, 0, "out"), (24, -0.14, "io"), (48, 0.08, "io"), (64, 0, "io")])
for st in star_eyes:
    celebrate.key(st, "rotation", [(0, 0, "hold"), (7, -0.6, "out"), (40, 0, "io"), (90, 0, "hold")])
    celebrate.key(st, "scaleX", [(0, 0.4, "hold"), (7, 0.4, "back"), (20, 1.1, "io"), (40, 1, "hold"), (90, 1, "hold")])
    celebrate.key(st, "scaleY", [(0, 0.4, "hold"), (7, 0.4, "back"), (20, 1.1, "io"), (40, 1, "hold"), (90, 1, "hold")])
celebrate.key(burst, "opacity", [(0, 0, "hold"), (12, 0, "io"), (18, 1, "io"), (44, 1, "io"), (66, 0, "hold"), (90, 0, "hold")])
for n, (spark, (tx, ty)) in enumerate(burst_parts):
    d = n % 2 * 3
    to_x, to_y = at(spark, tx, ty)
    celebrate.key(spark, "x", [(0, spark.lx, "hold"), (12 + d, spark.lx, "out"), (58, to_x, "hold"), (90, to_x, "hold")])
    celebrate.key(spark, "y", [(0, spark.ly, "hold"), (12 + d, spark.ly, "out"), (58, to_y, "hold"), (90, to_y, "hold")])
    celebrate.key(spark, "scaleX", [(0, 0.3, "hold"), (12 + d, 0.3, "back"), (28 + d, 1.2, "io"), (62, 0.3, "hold")])
    celebrate.key(spark, "scaleY", [(0, 0.3, "hold"), (12 + d, 0.3, "back"), (28 + d, 1.2, "io"), (62, 0.3, "hold")])
# The fish leaps up once the cat has landed, so the two never overlap.
celebrate.key(fish_node, "opacity", [(0, 0, "hold"), (36, 0, "io"), (46, 1, "io"), (74, 1, "io"), (88, 0, "hold"),
                                     (90, 0, "hold")])
celebrate.key(fish_node, "x", [(0, fish_node.lx - 14, "hold"), (36, fish_node.lx - 14, "soft"), (88, fish_node.lx + 14, "hold"),
                               (90, fish_node.lx + 14, "hold")])
celebrate.key(fish_node, "y", [(0, fish_node.ly + 30, "hold"), (36, fish_node.ly + 30, "out"), (56, fish_node.ly, "io"),
                               (88, fish_node.ly + 5, "hold"), (90, fish_node.ly + 5, "hold")])
celebrate.key(fish_node, "rotation", [(0, -0.5, "hold"), (36, -0.5, "io"), (52, 0, "io"), (60, 0.25, "io"),
                                      (68, -0.2, "io"), (76, 0.1, "io"), (88, 0.3, "hold")])
orbit = [(6 + round(n * 78 / 12), (120 - 88 * math.cos(n * math.pi / 6), 104 - 64 * math.sin(n * math.pi / 6)), "lin")
         for n in range(13)]
orb_path(celebrate, [(0, (34, 104), "io")] + orbit)
pose(celebrate, [0], {})
pose(celebrate, [7, 72], star_face)
pose(celebrate, [90], {})
animations.append(celebrate)

# Pet: happy eyes, a lean into the hand with ears back, a purr and a heart; the orb hops.
pet = Anim("Pet", 110, loop="oneShot")
pet_face = {(eyes, "opacity"): 0.0, (eyes_happy, "opacity"): 1.0, (blush, "opacity"): 1.0,
            (head_tilt, "rotation"): 0.16, (head_tilt, "y"): head_tilt.ly + 1.5, (cat, "rotation"): 0.035,
            (ears["L"], "rotation"): -0.22, (ears["R"], "rotation"): 0.22}
pet.key(heart_node, "opacity", [(0, 0, "hold"), (10, 0, "io"), (22, 1, "io"), (78, 1, "io"), (98, 0, "hold"), (110, 0, "hold")])
pet.key(heart_node, "y", [(0, heart_node.ly + 6, "hold"), (10, heart_node.ly + 6, "soft"), (98, heart_node.ly - 24, "hold"),
                          (110, heart_node.ly - 24, "hold")])
pet.key(heart_node, "scaleX", [(0, 0.3, "hold"), (10, 0.3, "back"), (26, 1, "io"), (98, 1.1, "hold")])
pet.key(heart_node, "scaleY", [(0, 0.3, "hold"), (10, 0.3, "back"), (26, 1, "io"), (98, 1.1, "hold")])
pet.key(torso, "scaleX", [(0, 1, "hold")] + [(f, 1.012 if (f // 10) % 2 else 1, "io") for f in range(20, 90, 10)] +
        [(110, 1, "hold")])
orb_path(pet, [(0, (60, 88), "io"), (14, (58, 70), "out"), (30, (58, 86), "in"), (44, (58, 72), "out"), (58, (58, 86), "in"),
               (72, (58, 76), "out"), (86, (58, 88), "io"), (110, (64, 96), "io")])
pose(pet, [0], {})
pose(pet, [16, 88], pet_face)
pose(pet, [110], {})
animations.append(pet)

# Companion game poses keep the chest steady for the native, species-specific catch.
proud = Anim("Proud Catch", 150)
pose(proud, [0, 150], {(eyes, "opacity"): 0.0, (eyes_happy, "opacity"): 1.0,
                      (blush, "opacity"): 0.5, (head_tilt, "rotation"): -0.025,
                      (ears["L"], "rotation"): 0.06, (ears["R"], "rotation"): -0.06})
animations.append(proud)
curious = Anim("Curious Catch", 150)
pose(curious, [0, 150], {(head_tilt, "rotation"): 0.13, (eyes, "scaleY"): 1.12,
                        (pupils["L"], "opacity"): 1.0, (pupils["R"], "opacity"): 1.0})
animations.append(curious)
effort = Anim("Fishing Effort", 90)
pose(effort, [0, 90], {(head_tilt, "rotation"): -0.065, (eyes, "scaleY"): 0.8,
                      (cat, "rotation"): -0.025, (ears["L"], "rotation"): 0.13,
                      (ears["R"], "rotation"): -0.13})
animations.append(effort)
focus = Anim("Quiet Focus", 180)
pose(focus, [0, 180], {(eyes, "scaleY"): 0.45, (orb_glow, "opacity"): 0.45})
focus.key(ears["L"], "rotation", [(0, 0, "hold"), (125, 0, "out"), (132, -0.05, "io"), (147, 0, "hold"), (180, 0, "hold")])
animations.append(focus)

# Coats: one frame each, holding every themed colour.
coat_anims = {}
for key in ("ink", "snow"):
    a = Anim("Coat " + key.title(), 1, loop="oneShot")
    for role, solids in COLORS.items():
        for solid in solids:
            a.key(solid, "color", [(0, PALETTES[key][role])])
    for role, stops in STOPS.items():
        for stop, alpha in stops:
            color = PALETTES[key][role]
            a.key(stop, "stop", [(0, (alpha + color[2:]) if alpha else color)])
    coat_anims[key] = a
    animations.append(a)


# ---------------------------------------------------------- state machine

def enum_condition(prop, value):
    return El("TransitionViewModelCondition", opValue="equal").add(
        El("TransitionPropertyViewModelComparator").add(
            El("BindablePropertyEnum").add(El("DataBindContext", sourcePathIds=vm_path(prop), propertyKey=637))),
        El("TransitionValueEnumComparator", value=value.id))


def trigger_condition(prop):
    return El("TransitionViewModelCondition").add(
        El("TransitionPropertyViewModelComparator").add(
            El("BindablePropertyTrigger").add(El("DataBindContext", sourcePathIds=vm_path(prop), propertyKey=686))),
        El("TransitionValueTriggerComparator"))


def layer(name, entry_to, states, any_transitions=()):
    lyr = El("StateMachineLayer", name=name)
    any_state = El("AnyState", x=0, y=-140)
    for t in any_transitions:
        any_state.add(t)
    lyr.add(any_state, El("ExitState", x=0, y=260),
            El("EntryState", x=-220, y=60).add(El("StateTransition", stateToId=entry_to.id)))
    lyr.add(*states)
    return lyr


def astate(anim, x, y):
    return El("AnimationState", x=x, y=y, animationId=anim.id)


def always(anim):
    s = astate(anim, 0, 60)
    return layer(anim.el.attrs["name"], s, [s])


# Tail speed follows the mood.
s_tail_slow, s_tail_fast = astate(tail_slow, 0, 0), astate(tail_fast, 240, 120)
for m in ("watch", "play"):
    s_tail_slow.add(El("StateTransition", stateToId=s_tail_fast.id, duration=450).add(enum_condition(vm_mood, MOOD[m])))
for m in ("idle", "sleep"):
    s_tail_fast.add(El("StateTransition", stateToId=s_tail_slow.id, duration=600).add(enum_condition(vm_mood, MOOD[m])))
tail_layer = layer("Tail", s_tail_slow, [s_tail_slow, s_tail_fast])

mood_states = {"idle": astate(idle, 0, 0), "sleep": astate(sleep, 260, -60),
               "watch": astate(watch, 260, 100), "play": astate(play, 520, 20),
               "proud": astate(proud, 760, 0), "curious": astate(curious, 760, 120),
               "effort": astate(effort, 760, 240), "focus": astate(focus, 760, 360)}
s_celebrate = astate(celebrate, 260, 300)
s_pet = astate(pet, 520, 300)
s_celebrate.attrs["reset"] = True
s_pet.attrs["reset"] = True
for name, st in mood_states.items():
    for other, target in mood_states.items():
        if other == name:
            continue
        duration = 700 if "sleep" in (name, other) else (180 if other in ("proud", "curious", "effort", "focus") else 420)
        st.add(El("StateTransition", stateToId=target.id, duration=duration).add(enum_condition(vm_mood, MOOD[other])))
for finisher in (s_celebrate, s_pet):
    for other, target in mood_states.items():
        finisher.add(El("StateTransition", stateToId=target.id, duration=320, enableExitTime=True,
                        exitTimeIsPercetange=True, exitTime=100).add(enum_condition(vm_mood, MOOD[other])))
mood_layer = layer("Mood", mood_states["idle"], [*mood_states.values(), s_celebrate, s_pet], any_transitions=[
    El("StateTransition", stateToId=s_celebrate.id, duration=120).add(trigger_condition(vm_celebrate)),
    El("StateTransition", stateToId=s_pet.id, duration=160).add(trigger_condition(vm_pet)),
])

s_ink, s_snow = astate(coat_anims["ink"], 0, 0), astate(coat_anims["snow"], 260, 0)
s_ink.add(El("StateTransition", stateToId=s_snow.id, duration=400).add(enum_condition(vm_coat, COAT["snow"])))
s_snow.add(El("StateTransition", stateToId=s_ink.id, duration=400).add(enum_condition(vm_coat, COAT["ink"])))
coat_layer = layer("Coat", s_ink, [s_ink, s_snow])

pet_listener = El("StateMachineListenerSingle", targetId=hit.id, listenerTypeValue="click", name="Pet").add(
    El("ListenerViewModelChange").add(
        El("BindablePropertyTrigger", propertyValue=1).add(
            El("DataBindContext", sourcePathIds=vm_path(vm_pet), propertyKey=686, direction=True))))

state_machine.add(pet_listener, always(breathe), always(blink), always(drift), always(hover),
                  tail_layer, mood_layer, coat_layer)
artboard.add(state_machine)

# Look: host-driven numbers, eased by an interpolating converter.
smooth = El("DataConverterInterpolator", interpolationType="cubic", duration=0.28, name="Smooth Look").add(
    El("CubicEaseInterpolator", x1=0.25, y1=0.8, x2=0.35, y2=1))
joystick = El("Joystick", xId=look_x.id, yId=look_y.id, posX=120, posY=EYE_Y, width=120, height=120, name="Look").add(
    El("DataBindContext", sourcePathIds=vm_path(vm_look_x), propertyKey=299, converterId=smooth.id),
    El("DataBindContext", sourcePathIds=vm_path(vm_look_y), propertyKey=300, converterId=smooth.id))
artboard.add(joystick)

for a in animations:
    artboard.add(a.build())

doc = El("Rive", _id=False, version="1", kind="fragment").add(
    Comment("Generated by build_scene.py. Edit the script, not this file."),
    artboard, mood_enum, coat_enum, smooth, view_model)
ARGS.out.mkdir(parents=True, exist_ok=True)
(ARGS.out / "scene.rml").write_text(doc.render() + "\n")
if ARGS.out != HERE:
    (ARGS.out / "rive.yaml").write_text((HERE / "rive.yaml").read_text())
print(f"wrote {ARGS.out / 'scene.rml'} ({IDS.n} ids, {len(animations)} animations)")
