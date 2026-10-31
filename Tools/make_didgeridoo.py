"""Erzeugt Beispieltoene/Didgeridoo_D2.wav (synthetisch, frei verwendbar).

Lippen-Brummton auf D2 (unregelmaessige Pulsfolge) durch zwei wandernde Resonanzen
(Mundraum: "wa-u-i"), rhythmische Atemakzente und ab und zu ein Ueberblas-"Toot"
(Dezime hoeher). Aufruf: python make_didgeridoo.py <Beispieltoene-Ordner>
"""
import math
import random
import struct
import sys
import wave

SR = 44100
DUR = 6.0
F0 = 73.42   # D2


class Reso:
    def __init__(self):
        self.y1 = self.y2 = 0.0

    def run(self, x, f, q):
        w = 2 * math.pi * f / SR
        r = math.exp(-math.pi * f / (q * SR))
        y = x + 2 * r * math.cos(w) * self.y1 - r * r * self.y2
        self.y2, self.y1 = self.y1, y
        return y * (1 - r)


def main(out_dir):
    random.seed(11)
    n = int(DUR * SR)
    r1, r2, r3 = Reso(), Reso(), Reso()
    phase = 0.0
    left, right = [], []
    hist = [0.0] * 600
    for i in range(n):
        t = i / SR
        # Toot: kurz ueberblasen (Dezime hoeher) bei 2,1 s und 4,6 s
        toot = 0.0
        for c in (2.1, 4.6):
            if c < t < c + 0.45:
                toot = math.sin(math.pi * (t - c) / 0.45)
        f = F0 * (1 + 0.004 * math.sin(t * 5.1)) * (1 + 1.52 * toot * 0.0)  # Grundton bleibt
        phase += f / SR * (1 + random.uniform(-0.004, 0.004))
        x = 0.0
        if phase >= 1.0:
            phase -= 1.0
        # Lippenpuls: kurzer, asymmetrischer Impuls je Periode
        x = math.exp(-phase * 18) - 0.12
        # Mundraum: Formanten wandern ("wa-u-i"), Atemakzente alle ~0,7 s
        wah = 0.5 + 0.5 * math.sin(t * 2 * math.pi * 0.45) * math.sin(t * 2 * math.pi * 0.17 + 1)
        f1 = 380 + 520 * wah
        f2 = 1100 + 1300 * (1 - wah) * (0.6 + 0.4 * math.sin(t * 3.3))
        y = r1.run(x, f1, 7) * 1.0 + r2.run(x, f2, 10) * 0.55
        # Toot: Resonanz auf der Dezime (Ueberblaston)
        y += r3.run(x, F0 * 2.52 * 4, 25) * toot * 1.4
        breath = 1.0 - 0.35 * max(0.0, math.sin(t * 2 * math.pi / 0.7)) ** 8
        noise = random.uniform(-1, 1) * 0.02 * (1 - breath + 0.2)
        y = math.tanh((y * breath + noise) * 3.0)
        env = min(1.0, t / 0.08) * min(1.0, (DUR - t) / 0.3)
        y *= env
        hist[i % 600] = y
        left.append(y)
        right.append(0.85 * y + 0.15 * hist[(i - 421) % 600])
    m = max(max(abs(v) for v in left), max(abs(v) for v in right)) or 1.0
    g = 0.89 / m
    path = out_dir.rstrip('/\\') + '/Didgeridoo_D2.wav'
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<hh', int(l * g * 32767), int(r * g * 32767))
                               for l, r in zip(left, right)))
    print('  ' + path)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
