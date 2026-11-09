# GranularSynth - Icon fuer GranularHost.exe erzeugen
# Copyright (C) 2026 Matthias Haberecht - GPL v3 oder spaeter (siehe LICENSE.txt)
#
# Zeichnet eine dunkle Geraeteplatte mit bernsteinfarbenen Grains entlang einer Welle
# und schreibt Source/Host/GranularHost.ico (16..256 px). build.bat bindet es ueber HostIcon.rc ein.
# Aufruf: python Tools/make_host_icon.py
import math, os, random
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024                     # gross zeichnen, dann verkleinern (sauberes Antialiasing)

def make():
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    # Platte: Verlauf oben hell -> unten dunkel, abgerundet
    plate = Image.new('RGBA', (S, S))
    pd = ImageDraw.Draw(plate)
    for y in range(S):
        f = y / S
        pd.line([(0, y), (S, y)], fill=(int(70 - 38 * f), int(66 - 36 * f), int(62 - 34 * f), 255))
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([24, 24, S - 24, S - 24], radius=170, fill=255)
    img.paste(plate, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([24, 24, S - 24, S - 24], radius=170, outline=(120, 114, 108, 255), width=10)
    # Display-Fenster
    d.rounded_rectangle([120, 190, S - 120, S - 190], radius=60, fill=(18, 14, 11, 255),
                        outline=(8, 7, 6, 255), width=8)
    # Grains entlang einer Welle, mit Schein
    glow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    dots = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dots)
    rnd = random.Random(7)
    x0, x1, cy, amp = 180, S - 180, S / 2, 190
    for k in range(15):
        t = k / 14
        x = x0 + (x1 - x0) * t
        env = math.sin(math.pi * t) ** 0.8          # Huellkurve: Mitte am groessten
        y = cy - amp * env * math.sin(2 * math.pi * 1.25 * t) + rnd.uniform(-18, 18)
        r = 26 + 34 * env
        gd.ellipse([x - r * 2, y - r * 2, x + r * 2, y + r * 2], fill=(255, 150, 40, 90))
        dd.ellipse([x - r, y - r, x + r, y + r], fill=(255, int(170 + 50 * env), 80, 255))
    glow = glow.filter(ImageFilter.GaussianBlur(40))
    win = Image.new('L', (S, S), 0)
    ImageDraw.Draw(win).rounded_rectangle([128, 198, S - 128, S - 198], radius=54, fill=255)
    layer = Image.alpha_composite(glow, dots)
    img.paste(layer, (0, 0), Image.composite(layer, Image.new('RGBA', (S, S)), win).split()[3])
    # vier Schrauben
    for sx, sy in ((95, 95), (S - 95, 95), (95, S - 95), (S - 95, S - 95)):
        d.ellipse([sx - 34, sy - 34, sx + 34, sy + 34], fill=(22, 19, 17, 255))
        d.ellipse([sx - 27, sy - 27, sx + 27, sy + 27], fill=(120, 126, 134, 255))
        d.line([(sx - 18, sy + 18), (sx + 18, sy - 18)], fill=(30, 32, 36, 255), width=9)
    return img

if __name__ == '__main__':
    out = os.path.join(ROOT, 'Source', 'Host', 'GranularHost.ico')
    big = make()
    big.resize((256, 256), Image.LANCZOS).save(
        out, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    big.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, 'bin', 'host_icon_vorschau.png'))
    print('geschrieben:', out)
