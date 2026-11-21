"""Bake the neon sign template atlas.

Usage:  python Tools/make_sign_atlas.py

Renders every template in TEMPLATES (real lettering: Japanese, Kowloon-style Chinese, Soviet
Cyrillic, English - invented shop names only, no real brands) with the OFL fonts in
Tools/fonts, and stores per texel:
    R = signed distance field of the lettering (0.5 = edge, > 0.5 inside, +-SPREAD px range)
    G = coverage (anti-aliased mask; its mip chain doubles as a letter-shaped glow)
Outputs Assets/MatrixCocoa/Textures/SignAtlas.png and SignAtlas.json (the template index read
by Editor/Gen/CitySignBuilder.cs). Re-run after editing TEMPLATES, then Matrix Cocoa > Rebuild Scene.

Fonts (SIL Open Font License, see Tools/fonts/OFL-*.txt): Noto Sans JP, Noto Serif JP,
Oswald, Russo One.
"""
import json
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import distance_transform_edt

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FONTS = os.path.join(ROOT, "Tools", "fonts")
OUT_PNG = os.path.join(ROOT, "Assets", "MatrixCocoa", "Textures", "SignAtlas.png")
OUT_JSON = os.path.join(ROOT, "Assets", "MatrixCocoa", "Textures", "SignAtlas.json")

CH = 96        # final pixels per character cell / line height
SS = 4         # supersampling for the distance field
SPREAD = 10.0  # distance field range (final px) each side of the edge
PAD = 24       # empty texels between templates (mip bleeding)
ATLAS_W = 4096

FONT = {
    "sans_light": ("NotoSansJP.ttf", 300),
    "sans_bold": ("NotoSansJP.ttf", 800),
    "serif": ("NotoSerifJP.ttf", 800),
    "oswald": ("Oswald.ttf", 600),
    "oswald_light": ("Oswald.ttf", 300),
    "russo": ("RussoOne.ttf", None),
}

# (text, orientation, font, script, optional subline)
#   v  = vertical, one character per cell (blades)
#   h  = one horizontal line
#   h2 = big line + a small second line underneath
JP_V = ["ラーメン", "居酒屋", "寿司", "焼肉", "カラオケ", "薬局", "質屋", "麻雀", "喫茶", "珈琲", "ホテル",
        "酒場", "映画館", "電気", "時計", "写真", "理髪", "銀行", "病院", "中華料理", "新宿", "未来", "東京",
        "夢", "愛", "龍", "天国", "電脳", "地下鉄", "交番", "宝石", "酒", "薬", "湯", "拉麺", "餃子", "天ぷら",
        "蕎麦", "牛丼", "弁当", "漢方", "鍼灸", "不動産", "金融", "両替", "占い", "骨董", "古本", "修理",
        "パチンコ", "ビデオ", "スナック", "タバコ", "ゲーム", "旅館", "銭湯", "夜鳴き", "大衆食堂", "鉄板焼"]
CN_V = ["大押", "茶餐廳", "酒家", "藥行", "金行", "涼茶", "牙科", "當", "夜總會", "麻雀館", "粥麵", "燒臘",
        "金舖", "海鮮", "冰室", "按摩", "跌打", "押"]
RU_H = ["АПТЕКА", "ГАСТРОНОМ", "КИНО", "ГОСТИНИЦА", "ХЛЕБ", "МОЛОКО", "РЕСТОРАН", "БАР", "ТЕАТР", "МЕТРО",
        "ЦВЕТЫ", "КНИГИ", "ПИВО", "ЧАСЫ", "РЫБА", "ОВОЩИ", "КАФЕ", "ТАКСИ", "ПОЧТА", "ТЕЛЕГРАФ", "УНИВЕРМАГ",
        "СБЕРКАССА", "ВИНО", "СОКИ", "ПЕЛЬМЕННАЯ", "ЧЕБУРЕЧНАЯ", "ДИСКОТЕКА", "КОСМОС", "РАДУГА", "СПУТНИК",
        "ЗАРЯ", "ВОСТОК", "ОКЕАН", "РОДИНА", "МИР", "РЕМОНТ", "ОБУВЬ", "ТАБАК", "ВОКЗАЛ", "ГАЗЕТЫ",
        "АНГАР 7"]   # (the last one hangs over the station hangar)
EN_H = ["HOTEL", "BAR", "NOODLES", "PAWN", "OPEN 24H", "CLINIC", "TAXI", "LIQUOR", "KARAOKE", "MOTEL",
        "CASINO", "DINER", "SUSHI", "CAFE", "PHARMACY", "NO VACANCY", "VACANCY", "ARCADE", "CLUB", "DANCE",
        "BOOKS", "TATTOO", "REPAIR", "CHECKS CASHED", "OPEN", "NOODLE BAR", "COCKTAILS", "VIDEO", "LAUNDRY",
        "ELECTRONICS", "SYNTHETICS", "ORIGAMI", "BIOTECH", "PARTS", "FISH MARKET"]
JP_H = ["ラーメン", "カラオケ", "ホテル", "パチンコ", "居酒屋", "焼肉", "寿司", "喫茶店", "電気店", "質屋",
        "ゲームセンター", "スナック", "クリーニング", "薬局", "中華料理", "回転寿司", "立ち飲み"]
H2 = [("寿司", "SUSHI BAR"), ("珈琲", "COFFEE"), ("ホテル", "HOTEL"), ("薬局", "PHARMACY"),
      ("ラーメン", "NOODLES"), ("居酒屋", "IZAKAYA"), ("АПТЕКА", "24 ЧАСА"), ("КИНО", "СЕАНСЫ"),
      ("麻雀", "MAHJONG"), ("質屋", "PAWN SHOP"), ("BAR", "OPEN LATE"), ("HOTEL", "VACANCY"),
      ("ГАСТРОНОМ", "№ 1"), ("中華料理", "CHINESE FOOD"), ("カラオケ", "KARAOKE BOX")]

TEMPLATES = []
for t in JP_V:
    TEMPLATES.append((t, "v", "sans_light", "jp", None))
    TEMPLATES.append((t, "v", "serif" if len(t) <= 3 else "sans_bold", "jp", None))
for t in CN_V:
    TEMPLATES.append((t, "v", "serif", "cn", None))
    TEMPLATES.append((t, "v", "sans_light", "cn", None))
for t in RU_H:
    TEMPLATES.append((t, "h", "russo" if len(t) <= 7 else "oswald", "ru", None))
for t in EN_H:
    TEMPLATES.append((t, "h", "oswald" if len(t) > 6 else "russo", "en", None))
    TEMPLATES.append((t, "h", "oswald_light", "en", None))
for t in JP_H:
    TEMPLATES.append((t, "h", "sans_bold", "jp", None))
for a, b in H2:
    TEMPLATES.append((a, "h2", "sans_bold" if not a.isascii() else "russo", "mix", b))


def load_font(key, size):
    name, wght = FONT[key]
    f = ImageFont.truetype(os.path.join(FONTS, name), size)
    if wght is not None:
        try:
            f.set_variation_by_axes([wght])
        except Exception:
            pass
    return f


ROTATE_IN_VERTICAL = set("ー〜～-")


def render_vertical(text, fkey):
    n = len(text)
    cell = CH * SS
    img = Image.new("L", (cell, cell * n), 0)
    f = load_font(fkey, int(cell * 0.8))
    for i, ch in enumerate(text):
        g = Image.new("L", (cell, cell), 0)
        d = ImageDraw.Draw(g)
        bb = d.textbbox((0, 0), ch, font=f)
        x = (cell - (bb[2] - bb[0])) / 2 - bb[0]
        y = (cell - (bb[3] - bb[1])) / 2 - bb[1]
        d.text((x, y), ch, font=f, fill=255)
        if ch in ROTATE_IN_VERTICAL:
            g = g.rotate(-90)
        img.paste(g, (0, i * cell))
    return img


def render_line(text, fkey, height_px, size_frac):
    f = load_font(fkey, int(height_px * size_frac))
    tmp = ImageDraw.Draw(Image.new("L", (8, 8)))
    bb = tmp.textbbox((0, 0), text, font=f)
    w = bb[2] - bb[0]
    margin = int(height_px * 0.22)
    img = Image.new("L", (w + 2 * margin, height_px), 0)
    d = ImageDraw.Draw(img)
    d.text((margin - bb[0], (height_px - (bb[3] - bb[1])) / 2 - bb[1]), text, font=f, fill=255)
    return img


def render(t):
    text, orient, fkey, script, sub = t
    if orient == "v":
        return render_vertical(text, fkey)
    if orient == "h":
        return render_line(text, fkey, CH * SS, 0.72)
    # h2: big line over a small line, centred
    big = render_line(text, fkey, CH * SS, 0.74)
    small = render_line(sub, "oswald", int(CH * SS * 0.5), 0.72)
    w = max(big.width, small.width)
    img = Image.new("L", (w, big.height + small.height), 0)
    img.paste(big, ((w - big.width) // 2, 0))
    img.paste(small, ((w - small.width) // 2, big.height))
    return img


def to_sdf(img):
    # make width/height multiples of SS
    w = (img.width + SS - 1) // SS * SS
    h = (img.height + SS - 1) // SS * SS
    canvas = Image.new("L", (w, h), 0)
    canvas.paste(img, (0, 0))
    m = np.asarray(canvas) > 127
    inside = distance_transform_edt(m)
    outside = distance_transform_edt(~m)
    sd = (inside - outside) / SS
    H, W = h // SS, w // SS
    sd = sd.reshape(H, SS, W, SS).mean(axis=(1, 3))
    cov = m.astype(np.float32).reshape(H, SS, W, SS).mean(axis=(1, 3))
    r = np.clip(0.5 + sd / (2 * SPREAD), 0, 1)
    return np.stack([r, cov], axis=-1)


def main():
    items = []
    for t in TEMPLATES:
        rg = to_sdf(render(t))
        items.append((t, rg))
    # shelf packing, tallest first
    order = sorted(range(len(items)), key=lambda i: -items[i][1].shape[0])
    x = y = shelf_h = 0
    placed = {}
    for i in order:
        h, w = items[i][1].shape[:2]
        if x + w + PAD > ATLAS_W:
            x, y, shelf_h = 0, y + shelf_h + PAD, 0
        placed[i] = (x + PAD, y + PAD)
        x += w + PAD
        shelf_h = max(shelf_h, h)
    used_h = y + shelf_h + 2 * PAD
    atlas_h = (used_h + 127) // 128 * 128          # block-compressible, no wasted power-of-two space
    if atlas_h > 4096:
        raise SystemExit(f"atlas overflow: need {used_h}px")
    atlas = np.zeros((atlas_h, ATLAS_W, 4), np.uint8)
    atlas[..., 3] = 255
    index = []
    for i, (t, rg) in enumerate(items):
        px, py = placed[i]
        h, w = rg.shape[:2]
        atlas[py:py + h, px:px + w, 0] = (rg[..., 0] * 255 + 0.5).astype(np.uint8)
        atlas[py:py + h, px:px + w, 1] = (rg[..., 1] * 255 + 0.5).astype(np.uint8)
        text, orient, fkey, script, sub = t
        # uv rect with v measured from the BOTTOM (Unity convention)
        index.append({
            "text": text if sub is None else f"{text} / {sub}",
            "orient": orient, "font": fkey, "script": script,
            "u0": px / ATLAS_W, "v0": 1 - (py + h) / atlas_h, "u1": (px + w) / ATLAS_W, "v1": 1 - py / atlas_h,
            "aspect": w / h,                      # width / height
            "units": len(text) if orient == "v" else 1,
        })
    os.makedirs(os.path.dirname(OUT_PNG), exist_ok=True)
    Image.fromarray(atlas, "RGBA").save(OUT_PNG)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump({"width": ATLAS_W, "height": atlas_h, "spread": SPREAD, "templates": index}, f, ensure_ascii=False, indent=1)
    print(f"{len(index)} templates -> {OUT_PNG} ({ATLAS_W}x{atlas_h}, {used_h}px used)")


if __name__ == "__main__":
    main()
