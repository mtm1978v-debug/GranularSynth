"""Erzeugt Beispieltoene/Kettensaege.wav (synthetisch, frei verwendbar).

Zweitakt-Motor: Zuendimpulse mit der Drehzahl, jeder Impuls regt drei Resonanzen an
(Auspuff/Gehaeuse), dazu Kettenrasseln (Rauschen im Takt der Zuendung) und weiches
Uebersteuern. Verlauf: Leerlauf -> hochdrehen -> Schnitt unter Last (Drehzahl wackelt)
-> auslaufen. Aufruf: python make_kettensaege.py <Beispieltoene-Ordner>
"""
import math
import random
import struct
import sys
import wave

SR = 44100
DUR = 4.0


def rpm_curve(t):
    # Zuendfrequenz in Hz
    if t < 0.5:
        return 48 + 4 * math.sin(t * 9)                  # Leerlauf, unruhig
    if t < 0.9:
        x = (t - 0.5) / 0.4
        return 48 + (150 - 48) * (x * x * (3 - 2 * x))    # hochdrehen
    if t < 3.0:
        load = 0.85 + 0.15 * math.sin(t * 6.3) * math.sin(t * 2.1)
        return 150 * load + 6 * math.sin(t * 31)          # Schnitt: Drehzahl sackt und wackelt
    x = min(1.0, (t - 3.0) / 0.9)
    return 150 - (150 - 55) * x                           # auslaufen


class Reso:
    """Zweipol-Resonator (gedaempfte Schwingung)."""
    def __init__(self, f, q):
        w = 2 * math.pi * f / SR
        r = math.exp(-math.pi * f / (q * SR))
        self.a1 = 2 * r * math.cos(w)
        self.a2 = -r * r
        self.y1 = self.y2 = 0.0

    def run(self, x):
        y = x + self.a1 * self.y1 + self.a2 * self.y2
        self.y2, self.y1 = self.y1, y
        return y


def main(out_dir):
    random.seed(7)
    n = int(DUR * SR)
    res = [Reso(310, 6), Reso(1250, 9), Reso(3100, 12)]
    gains = [1.0, 0.55, 0.3]
    phase = 0.0
    lp = 0.0
    left, right = [], []
    delay = [0.0] * 400
    for i in range(n):
        t = i / SR
        f = rpm_curve(t)
        phase += f / SR
        pulse = 0.0
        if phase >= 1.0:
            phase -= 1.0
            pulse = 1.0 + random.uniform(-0.25, 0.25)   # unregelmaessige Zuendung
        # Kettenrasseln: Rauschen, im Takt der Zuendung moduliert, staerker unter Last
        load = 1.0 if 0.9 < t < 3.0 else 0.35
        noise = random.uniform(-1, 1) * (0.25 + 0.75 * (1 - phase)) * 0.35 * load
        lp += (noise - lp) * 0.35
        x = sum(g * r.run(pulse * 0.6) for g, r in zip(gains, res)) * 0.12 + lp
        x = math.tanh(x * 2.2)                            # Motor klingt angezerrt
        # Ein-/Ausblenden
        env = min(1.0, t / 0.03) * min(1.0, (DUR - t) / 0.15)
        x *= env
        # leichte Stereobreite: kurze Verzoegerung rechts
        delay[i % 400] = x
        left.append(x)
        right.append(0.8 * x + 0.2 * delay[(i - 331) % 400])
    m = max(max(abs(v) for v in left), max(abs(v) for v in right)) or 1.0
    g = 0.89 / m
    path = out_dir.rstrip('/\\') + '/Kettensaege.wav'
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<hh', int(l * g * 32767), int(r * g * 32767))
                               for l, r in zip(left, right)))
    print('  ' + path)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
