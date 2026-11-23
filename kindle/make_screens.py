"""Bakes the static parts of the self.v2 Kindle screens (page texture, textured tiles,
folders, fixed labels) into greyscale PNGs at the Paperwhite 2's exact size, and writes
layout.lua so the plugin knows where to draw the live text and where the tap zones are.

Run after changing the design:  python kindle/make_screens.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageOps

HERE = Path(__file__).parent
ART = HERE / "art"
ROOT = HERE.parent
PLUGIN = ROOT / "koreader/plugins/selfv2.koplugin"
OUT = PLUGIN / "screens"
W, H = 758, 1024
PAD = 30
NIGHT = False  # set by the night pass in __main__


def INK(v, a=255):
    """Neutral colour for page and card artwork: as-is by day, reversed at night.
    Textured tiles keep their own colours in both modes."""
    if not NIGHT:
        return (v, v, v, a)
    n = 42 if v == 255 else 255 - v
    return (n, n, n, a)

MARC = str(ROOT / "fonts/Marcellus-Regular.ttf")
SANS = str(ROOT / "fonts/DMSans.ttf")


def f(path, size, weight=None):
    fnt = ImageFont.truetype(path, size)
    if weight:
        try:
            fnt.set_variation_by_axes([14, weight])
        except Exception:
            pass
    return fnt


def page():
    bg = Image.open(ART / "lace_soft.jpg").convert("L")
    sc = max(W / bg.width, H / bg.height)
    bg = bg.resize((int(bg.width * sc) + 1, int(bg.height * sc) + 1)).crop((0, 0, W, H))
    if NIGHT:
        bg = ImageEnhance.Brightness(ImageOps.invert(bg)).enhance(0.32)
    return bg.convert("RGBA")


def rmask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w - 1, h - 1), radius=r, fill=255)
    return m


def textured(im, rect, tex, darkness=0.5, r=28):
    x, y, w, h = rect
    t = Image.open(ART / tex).convert("L")
    sc = max(w / t.width, h / t.height)
    t = t.resize((int(t.width * sc) + 1, int(t.height * sc) + 1))
    t = t.crop(((t.width - w) // 2, (t.height - h) // 2, (t.width - w) // 2 + w, (t.height - h) // 2 + h))
    t = ImageEnhance.Brightness(t).enhance(darkness * (0.8 if NIGHT else 1)).convert("RGBA")
    im.paste(t, (x, y), rmask(w, h, r))


def card(im, rect, alpha=222, r=26, fill=255):
    x, y, w, h = rect
    ov = Image.new("RGBA", im.size, (0, 0, 0, 0))
    c = 30 if NIGHT and fill == 255 else fill
    ImageDraw.Draw(ov).rounded_rectangle((x, y, x + w, y + h), radius=r, fill=(c, c, c, alpha))
    im.alpha_composite(ov)


def folder(im, name, x, y, width, angle=6):
    fo = Image.open(ART / name).convert("RGBA")
    fo = fo.resize((width, int(fo.height * width / fo.width)), Image.LANCZOS).rotate(angle, expand=True, resample=Image.BICUBIC)
    sh = Image.new("RGBA", fo.size, (0, 0, 0, 0))
    sh.putalpha(fo.getchannel("A").point(lambda a: int(a * 0.35)))
    im.alpha_composite(sh, (x, y + 4))
    im.alpha_composite(fo, (x, y))


def back_pill(d):
    d.rounded_rectangle((PAD, 20, PAD + 116, 60), radius=20, fill=INK(255, 230))
    d.line((PAD + 22, 40, PAD + 30, 32), fill=INK(17, 255), width=3)
    d.line((PAD + 22, 40, PAD + 30, 48), fill=INK(17, 255), width=3)
    d.text((PAD + 40, 40), "Home", font=f(SANS, 16, 700), fill=INK(17, 255), anchor="lm")


def save(im, name):
    OUT.mkdir(parents=True, exist_ok=True)
    if NIGHT:
        name = name.replace(".png", "_night.png")
    im.convert("L").save(OUT / name, optimize=True)


# ------------------------------------------------------------------ layout
L = {
    "home": {
        "label": (PAD, 24), "pills_y": 104,
        "cont": (PAD, 156, 698, 122),
        "dash": (PAD, 294, 340, 250), "focus": (388, 294, 340, 250),
        "papers": (PAD, 558, 340, 200), "subs": (388, 558, 340, 200),
        "library": (PAD, 772, 698, 112),
        "download": (PAD, 904, 340, 72), "wifi": (388, 904, 165, 72), "settings": (563, 904, 165, 72),
    },
    "papers": {
        "back": (PAD, 20, 116, 40), "sub": (PAD, 128),
        "tiles": [(PAD, 166, 341, 142), (387, 166, 341, 142), (PAD, 320, 341, 142), (387, 320, 341, 142)],
        "panel": (PAD, 476, 698, 526), "panel_sub": (52, 528),
        "btn_open": (586, 490, 124, 42), "btn_read": (454, 490, 124, 42),
        "rows_y": 570, "row_h": 84, "row_x": 98, "row_w": 608,
    },
    "subs": {
        "back": (PAD, 20, 116, 40), "sub": (PAD, 128),
        "pick": (PAD, 166, 698, 150),
        "panel": (PAD, 330, 698, 672),
        "btn_prev": (586, 344, 56, 40), "btn_next": (652, 344, 56, 40), "page": (566, 364),
        "rows_y": 398, "row_h": 98, "row_x": 78, "row_w": 626, "rows": 6,
    },
}


def bake_home():
    im = page()
    d = ImageDraw.Draw(im)
    l = L["home"]
    d.text((PAD, 44), "Rajeshwari", font=f(MARC, 44), fill=INK(17, 255))
    card(im, l["cont"])
    d.text((52, 172), "CONTINUE READING", font=f(SANS, 13, 700), fill=INK(85, 255))
    # tiles
    textured(im, l["dash"], "zebra_s.jpg", 0.55)
    textured(im, l["focus"], "lace_s.jpg", 0.5)
    textured(im, l["papers"], "cow_s.jpg", 0.52)
    textured(im, l["subs"], "fawn_s.jpg", 0.55)
    textured(im, l["library"], "leopard_s.jpg", 0.6)
    d = ImageDraw.Draw(im)
    big, small = f(MARC, 34), f(SANS, 15)
    for key, title, sub in [("dash", "Dashboard", "Today · check-in · log · week"),
                            ("focus", "Focus board", "range · athleticism · a quiet mind")]:
        x, y, w, h = l[key]
        d.text((x + 20, y + h - 80), title, font=big, fill=(255, 255, 255, 255))
        d.text((x + 20, y + h - 30), sub, font=small, fill=(235, 235, 235, 255))
    for key, title in [("papers", "Today's papers"), ("subs", "Substacks")]:
        x, y, w, h = l[key]
        d.text((x + 20, y + h - 66), title, font=f(MARC, 28), fill=(255, 255, 255, 255))
    x, y, w, h = l["library"]
    d.text((x + 140, y + 30), "Library", font=f(MARC, 30), fill=(255, 255, 255, 255))
    d.text((x + 140, y + 68), "All your books in KOReader", font=small, fill=(235, 235, 235, 255))
    d.ellipse((x + w - 70, y + 32, x + w - 22, y + 80), fill=(255, 255, 255, 235))
    d.line((x + w - 52, y + 46, x + w - 42, y + 56), fill=(17, 17, 17, 255), width=3)
    d.line((x + w - 52, y + 66, x + w - 42, y + 56), fill=(17, 17, 17, 255), width=3)
    folder(im, "f_zebra.png", l["dash"][0] + 12, l["dash"][1] + 12, 112)
    folder(im, "folder_leoface.png", l["focus"][0] + 12, l["focus"][1] + 12, 112)
    folder(im, "f_blackcow.png", l["papers"][0] + 10, l["papers"][1] + 10, 92)
    folder(im, "f_fawn.png", l["subs"][0] + 10, l["subs"][1] + 10, 92)
    folder(im, "folder_leopard.png", l["library"][0] + 18, l["library"][1] + 10, 100)
    # bottom bar
    d = ImageDraw.Draw(im)
    x, y, w, h = l["download"]
    d.rounded_rectangle((x, y, x + w, y + h), radius=36, fill=INK(17, 235))
    d.text((x + w / 2, y + h / 2), "Download today's reads", font=f(SANS, 17, 700), fill=INK(255, 255), anchor="mm")
    for key, label in [("wifi", "Wi-Fi"), ("settings", "Settings")]:
        x, y, w, h = l[key]
        d.rounded_rectangle((x, y, x + w, y + h), radius=36, fill=INK(255, 225))
        d.text((x + w / 2, y + h / 2), label, font=f(SANS, 17, 700), fill=INK(17, 255), anchor="mm")
    save(im, "home.png")


def bake_papers():
    im = page()
    l = L["papers"]
    d = ImageDraw.Draw(im)
    back_pill(d)
    d.text((PAD, 74), "Today's papers", font=f(MARC, 42), fill=INK(17, 255))
    folder(im, "f_blackcow.png", W - PAD - 124, 20, 112)
    names = [("The Times of India", "cow_s.jpg", 0.5), ("The Hindu", "zebra_s.jpg", 0.52),
             ("The Economic Times", "fawn_s.jpg", 0.48), ("LiveLaw", "leopard_s.jpg", 0.5)]
    for rect, (name, tex, dk) in zip(l["tiles"], names):
        textured(im, rect, tex, dk, 24)
        x, y, w, h = rect
        ImageDraw.Draw(im).text((x + 18, y + h - 22), name, font=f(MARC, 25), fill=(255, 255, 255, 255), anchor="ls")
    card(im, l["panel"], 230)
    d = ImageDraw.Draw(im)
    d.text((52, 492), "Today's summary", font=f(MARC, 26), fill=INK(17, 255))
    for n in range(5):
        y = l["rows_y"] + n * l["row_h"]
        d.ellipse((52, y, 82, y + 30), fill=INK(17, 255))
        d.text((67, y + 15), str(n + 1), font=f(SANS, 15, 700), fill=INK(255, 255), anchor="mm")
        if n < 4:
            d.line((52, y + l["row_h"] - 8, 706, y + l["row_h"] - 8), fill=INK(225, 255), width=1)
    save(im, "papers.png")


def bake_subs():
    im = page()
    l = L["subs"]
    d = ImageDraw.Draw(im)
    back_pill(d)
    d.text((PAD, 74), "Substacks", font=f(MARC, 42), fill=INK(17, 255))
    folder(im, "f_fawn.png", W - PAD - 124, 20, 112)
    textured(im, l["pick"], "fawn_s.jpg", 0.45, 26)
    d = ImageDraw.Draw(im)
    x, y, w, h = l["pick"]
    d.rounded_rectangle((x + 20, y + 16, x + 178, y + 42), radius=13, fill=(255, 255, 255, 255))
    d.text((x + 99, y + 29), "Pick of the morning", font=f(SANS, 13, 700), fill=(17, 17, 17, 255), anchor="mm")
    card(im, l["panel"], 230)
    d = ImageDraw.Draw(im)
    d.text((52, 346), "Latest posts", font=f(MARC, 26), fill=INK(17, 255))
    for n in range(l["rows"] - 1):
        y = l["rows_y"] + (n + 1) * l["row_h"] - 10
        d.line((52, y, 706, y), fill=INK(225, 255), width=1)
    save(im, "substacks.png")


def write_layout():
    def lua(v):
        if isinstance(v, dict):
            return "{" + ", ".join(f"{k} = {lua(x)}" for k, x in v.items()) + "}"
        if isinstance(v, (list, tuple)):
            return "{" + ", ".join(lua(x) for x in v) + "}"
        return str(v)
    (PLUGIN / "layout.lua").write_text("-- generated by kindle/make_screens.py; design coordinates for a 758x1024 screen\nreturn " + lua(L) + "\n")


if __name__ == "__main__":
    for NIGHT in (False, True):
        bake_home()
        bake_papers()
        bake_subs()
    NIGHT = False
    write_layout()
    fonts = PLUGIN / "fonts"
    fonts.mkdir(exist_ok=True)
    for src in ["Marcellus-Regular.ttf", "DMSans.ttf"]:
        (fonts / src).write_bytes((ROOT / "fonts" / src).read_bytes())
    print("baked →", OUT)
