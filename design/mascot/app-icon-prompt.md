# 灵猫应用图标

2026-10-17 使用内置 `image_gen` 生成；参考本项目 Rive 灵猫的 `ink-idle.png` 与 `ink-perched.png`。成品保存为 `assets/AppIcon.png`，由 `scripts/MakeIcon.swift` 加上 macOS 圆角、透明外边距及阴影，生成各尺寸 PNG 和应用 ICNS。

保留墨黑猫身、尖耳、薄荷色发光眼睛与弯尾；不添加嘴、鼻子或条纹。素材沿用 [ASSETS.md](../../ASSETS.md) 的许可范围。

## 完整生成提示词

```text
Use case: logo-brand
Asset type: final macOS app icon source artwork, square 1024 x 1024.
Primary request: replace an unrelated green blob icon with this app's own black spirit cat mascot, closely matching the two supplied reference images.
Input images: image 1 is the canonical seated cat identity reference; image 2 is the same canonical cat peeking over a card, identity and eyes reference. These are reference images, not images to reproduce as a sheet.
Subject: one charming ink-black cat with a large round head, two tall triangular ears, a compact seated body, two tiny paws, and a smooth curling tail on the right. Pure near-black silhouette, no nose, no mouth, no whiskers, no stripes, no pink ears. Two luminous pale mint oval eyes with delicate vertical dark pupils, quietly curious. Preserve the simple distinctive proportions of the reference cat.
Composition: centered iconic cat fills about 76 percent of the square height; ears fully visible and plenty of space around the tail. One single finished app icon artwork, not a mockup or a grid.
Scene/backdrop: edge-to-edge very pale cool mint background with extremely subtle lighting, no border and no pre-rounded tile; the build system will add macOS rounded corners and the outer shadow.
Style: precise softly dimensional 2D illustration, clean large forms, matte ink silhouette with only a very subtle mint edge light and soft contact shadow. Extremely restrained eye glow, crisp readable eyes and ears at small size. Friendly, calm, original desktop companion.
Constraints: no text, no letters, no logos, no UI, no scenery, no stars, no floating ornaments, no additional characters, no fuzzy fur, no shiny plastic, no heavy 3D treatment. Background fully opaque and fills the entire square.
```
