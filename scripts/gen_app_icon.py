#!/usr/bin/env python3
"""Niche app 图标生成器(一键复现/可调)。

设计 = 深石板 squircle 底 + 顶部黑刘海凹口 + 滑出白玻璃卡片内含蓝文件夹:
Niche 一语三关(词义=凹槽 / MacBook 刘海 / "从刘海滑出"的核心交互)。

无 svg 渲染器依赖:纯 PIL 4x 超采样画 1024 master,再用 sips 切全尺寸写进 AppIcon.appiconset。
改色/调形只需改下方常量/坐标后重跑:  python3 scripts/gen_app_icon.py
"""
import os
import subprocess
from PIL import Image, ImageDraw, ImageFilter

BASE = 1024
SS = 4                      # 超采样倍率
S = BASE * SS              # 4096 画布
ICONSET = os.path.normpath(os.path.join(
    os.path.dirname(__file__), "..", "Sources/Niche/Assets.xcassets/AppIcon.appiconset"))

def s(v):
    return int(round(v * SS))

def box(x0, y0, x1, y1):
    return [s(x0), s(y0), s(x1), s(y1)]

# ---- 配色 ----
BG_TOP = (62, 68, 86)      # 深石板蓝(顶)
BG_BOT = (28, 31, 42)      # 更深(底)
NOTCH  = (9, 10, 14)       # 刘海近黑
CARD_TOP = (255, 255, 255)
CARD_BOT = (229, 234, 243) # 卡片微冷白渐变
FOLDER   = (59, 130, 246)  # #3B82F6
FOLDER_TAB = (37, 99, 235) # #2563EB
FOLDER_HI  = (147, 197, 253)

def vgrad(w, h, top, bot):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)],
               fill=(round(top[0] + (bot[0]-top[0])*t),
                     round(top[1] + (bot[1]-top[1])*t),
                     round(top[2] + (bot[2]-top[2])*t)))
    return img

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# ---- squircle 主体(深色渐变 + 圆角 mask)----
M = 92                      # 四周留白(Apple 网格 ~100)
R = 190                     # squircle 圆角
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(box(M, M, BASE-M, BASE-M), radius=s(R), fill=255)
grad = vgrad(S, S, BG_TOP, BG_BOT).convert("RGBA")
img.paste(grad, (0, 0), mask)

draw = ImageDraw.Draw(img)

# 顶部一道极淡内高光(玻璃光泽)
sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sheen).rounded_rectangle(box(M, M, BASE-M, M+220), radius=s(R),
                                        fill=(255, 255, 255, 38))
sheen = sheen.filter(ImageFilter.GaussianBlur(s(36)))
sheen_masked = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sheen_masked.paste(sheen, (0, 0), mask)
img = Image.alpha_composite(img, sheen_masked)
draw = ImageDraw.Draw(img)

# ---- 刘海凹口(黑 pill,贴 body 顶居中,仅底部两角圆)----
nw, nh = 340, 74
nx0 = (BASE - nw) / 2
draw.rounded_rectangle(box(nx0, M, nx0+nw, M+nh), radius=s(34),
                       fill=NOTCH, corners=(False, False, True, True))

# ---- 滑出的白玻璃卡片(带柔和投影)----
cx0, cy0, cx1, cy1 = 232, 300, 792, 700
cR = 74
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(box(cx0, cy0+18, cx1, cy1+18), radius=s(cR),
                                         fill=(0, 0, 0, 105))
shadow = shadow.filter(ImageFilter.GaussianBlur(s(34)))
img = Image.alpha_composite(img, shadow)
cmask = Image.new("L", (S, S), 0)
ImageDraw.Draw(cmask).rounded_rectangle(box(cx0, cy0, cx1, cy1), radius=s(cR), fill=255)
cgrad = vgrad(S, S, CARD_TOP, CARD_BOT).convert("RGBA")
card_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
card_layer.paste(cgrad, (0, 0), cmask)
img = Image.alpha_composite(img, card_layer)
draw = ImageDraw.Draw(img)
draw.rounded_rectangle(box(cx0, cy0, cx1, cy1), radius=s(cR),
                       outline=(255, 255, 255, 200), width=s(2))

# ---- 文件夹(卡片中央,放大填充)----
fcx = BASE / 2
fy0, fy1 = 398, 612
fx0, fx1 = fcx-152, fcx+152
draw.rounded_rectangle(box(fx0, fy0+4, fx0+196, fy0+68), radius=s(24),
                       fill=FOLDER_TAB, corners=(True, True, True, False))
draw.rounded_rectangle(box(fx0, fy0+48, fx1, fy1), radius=s(30), fill=FOLDER)

# ---- 缩到 1024 master,存进 appiconset,再 sips 切全尺寸 ----
out = img.resize((BASE, BASE), Image.Resampling.LANCZOS)
master = os.path.join(ICONSET, "icon_1024.png")
out.save(master)
for px in (16, 32, 64, 128, 256, 512):
    subprocess.run(["sips", "-z", str(px), str(px), master,
                    "--out", os.path.join(ICONSET, f"icon_{px}.png")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("wrote AppIcon set →", ICONSET)
