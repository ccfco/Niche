#!/usr/bin/env python3
"""从 docs/assets/app-icon-source.png(圆形徽章原稿)生成 AppIcon.appiconset 全套 PNG。

原稿是纯黑方形画布上的圆形徽章(圆内底色均匀 ≈ #121213,四角纯黑),
macOS 26 会把图标强制套 squircle 遮罩,直接用会在四角露出圆形接缝。
处理方式:1024 画布整体铺圆内底色,原稿按比例放大后以圆形遮罩(内缩避开
边缘抗锯齿环)居中合成——底色一致所以拼接无缝,得到全出血方形图标。

调整构图只需改 SCALE(拱门占画布的比例)后重跑,再重新构建装机。
"""
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "docs/assets/app-icon-source.png"
ICONSET = REPO / "Sources/Niche/Assets.xcassets/AppIcon.appiconset"

CANVAS = 1024
SCALE = 1.05          # 原稿→画布的缩放系数,决定拱门占比(1.05 ≈ 图形高 79%)
CIRCLE_D = 1233       # 原稿中圆形徽章的实测直径
MASK_INSET = 6        # 圆形遮罩内缩像素,避开圆边与黑角之间的抗锯齿过渡环
BG = (18, 18, 19)     # 圆内底色实测值

src = Image.open(SOURCE).convert("RGB")
scaled_size = round(src.width * SCALE)
scaled = src.resize((scaled_size, scaled_size), Image.Resampling.LANCZOS)

r = (CIRCLE_D * SCALE) / 2 - MASK_INSET
cx = cy = scaled_size / 2
mask = Image.new("L", (scaled_size, scaled_size), 0)
ImageDraw.Draw(mask).ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)

canvas = Image.new("RGB", (CANVAS, CANVAS), BG)
offset = (CANVAS - scaled_size) // 2
canvas.paste(scaled, (offset, offset), mask)
canvas.save(ICONSET / "icon_1024.png")

for size in (512, 256, 128, 64, 32, 16):
    canvas.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET / f"icon_{size}.png")

print(f"已生成 icon_16..1024 共 7 张 → {ICONSET}")
