"""Erzeugt Beispieltoene/Knabenchor_C5.wav (synthetisch, frei verwendbar).

10 Kinderstimmen auf C5 ("Aah", langsam Richtung "Ooh"): je Stimme eine Wellentabelle aus
Obertoenen, deren Lautstaerke der Vokal-Huellkurve folgt (Kinder-Formanten liegen hoeher als bei
Erwachsenen), leicht verstimmt (+-7 Cent), eigenes Vibrato (5..6 Hz, verzoegert einsetzend),
Lautstaerke-Schwankung und etwas Atemrauschen. Aufruf: python make_knabenchor.py <Ordner>
"""
import math
import random
import struct
import sys
import wave

SR = 44100
DUR = 6.0
F0 = 523.25          # C5
TAB = 2048
VOICES = 10


def formant_env(f, formants):
    a = 0.0
    for fc, bw, g in formants:
        a += g / (1.0 + ((f - fc) / (bw * 0.5)) ** 2)
    return a


# Kinder-Formanten (Hz, Bandbreite, Gewicht)
AH = [(950, 160, 1.0), (1500, 200, 0.55), (3300, 320, 0.18)]
OO = [(500, 120, 1.0), (1000, 180, 0.35), (3000, 300, 0.08)]


def table(formants):
    t = [0.0] * TAB
    for h in range(1, 18):
        f = F0 * h
        if f > 9000:
            break
        a = formant_env(f, formants) * (0.9 ** h)
        ph = random.uniform(0, 2 * math.pi)
        for i in range(TAB):
            t[i] += a * math.sin(2 * math.pi * h * i / TAB + ph)
    m = max(abs(x) for x in t) or 1.0
    return [x / m for x in t]


def main(out_dir):
    random.seed(23)
    tab_ah = table(AH)
    tab_oo = table(OO)
    n = int(DUR * SR)
    left = [0.0] * n
    right = [0.0] * n
    for v in range(VOICES):
        det = 2 ** (random.uniform(-7, 7) / 1200)
        vib_f = random.uniform(5.0, 6.0)
        vib_d = random.uniform(0.004, 0.007)        # Vibratotiefe (Frequenzanteil)
        vib_on = random.uniform(0.5, 1.2)           # Vibrato setzt verzoegert ein
        amp_f = random.uniform(0.2, 0.5)
        pan = (v / (VOICES - 1)) * 2 - 1
        gl = math.sqrt((1 - pan) / 2) * 0.9
        gr = math.sqrt((1 + pan) / 2) * 0.9
        ph = random.random()
        start = random.uniform(0, 0.08)
        for i in range(n):
            t = i / SR
            if t < start:
                continue
            vib = 1 + vib_d * math.sin(2 * math.pi * vib_f * t + v) * min(1.0, max(0.0, (t - vib_on) / 0.8))
            ph += F0 * det * vib / SR
            ph -= int(ph)
            x = ph * TAB
            k = int(x)
            fr = x - k
            k2 = (k + 1) % TAB
            mix = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / DUR) * 0.9)   # Aah -> etwas Ooh
            s = ((tab_ah[k] + (tab_ah[k2] - tab_ah[k]) * fr) * (1 - mix * 0.6) +
                 (tab_oo[k] + (tab_oo[k2] - tab_oo[k]) * fr) * (mix * 0.6))
            env = min(1.0, (t - start) / 0.35) * min(1.0, (DUR - t) / 0.6)
            s *= env * (0.85 + 0.15 * math.sin(2 * math.pi * amp_f * t + v * 1.7))
            left[i] += s * gl
            right[i] += s * gr
    # Atem: leises, gefiltertes Rauschen
    lp = 0.0
    for i in range(n):
        t = i / SR
        lp += (random.uniform(-1, 1) - lp) * 0.25
        env = min(1.0, t / 0.35) * min(1.0, (DUR - t) / 0.6)
        b = lp * 0.04 * env
        left[i] += b
        right[i] += b * 0.9
    m = max(max(abs(x) for x in left), max(abs(x) for x in right)) or 1.0
    g = 0.89 / m
    path = out_dir.rstrip('/\\') + '/Knabenchor_C5.wav'
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<hh', int(l * g * 32767), int(r * g * 32767))
                               for l, r in zip(left, right)))
    print('  ' + path)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
