"""Erzeugt harmonische House-/Deep-House-Beispieltoene (synthetisch, frei verwendbar):
  House_Akkord_Cmaj9.wav  warme Flaeche Cmaj9 (C3 E3 G3 H3 D4), 3 verstimmte Saegezaehne je Ton
  Deep_Stab_Cm9.wav       Moll-9-Akkordstab (C3 Es3 G3 B3 D4), kurz, Filterhuellkurve
  Rhodes_C4.wav           E-Piano-Ton C4 (FM-artiger Anschlag, warmer Ausklang)
  Warmer_Bass_C2.wav      runder Sub-Bass C2
Bandbegrenzte Saegezahn-Wellentabelle (kein Aliasing). Aufruf: python make_house_samples.py <Ordner>
"""
import math
import random
import struct
import sys
import wave

SR = 44100
TAB = 4096


def midi_hz(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def saw_table(harmonics):
    t = [0.0] * TAB
    for h in range(1, harmonics + 1):
        a = 1.0 / h
        for i in range(TAB):
            t[i] += a * math.sin(2 * math.pi * h * i / TAB)
    m = max(abs(x) for x in t)
    return [x / m for x in t]


SAW = saw_table(40)      # fuer tiefe Toene; hoehere Toene werden danach tiefpassgefiltert


def lookup(tab, ph):
    x = ph * TAB
    k = int(x)
    f = x - k
    return tab[k % TAB] + (tab[(k + 1) % TAB] - tab[k % TAB]) * f


def save(path, left, right, peak=0.89):
    m = max(max(abs(x) for x in left), max(abs(x) for x in right)) or 1.0
    g = peak / m
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<hh', int(l * g * 32767), int(r * g * 32767))
                               for l, r in zip(left, right)))
    print('  ' + path)


def chord(notes, dur, attack, release, cutoff, cutoff_end, stab=False, detune=9):
    n = int(dur * SR)
    L = [0.0] * n
    R = [0.0] * n
    for note in notes:
        f = midi_hz(note)
        for v in range(3):
            d = 2 ** (((v - 1) * detune + random.uniform(-2, 2)) / 1200)
            ph = random.random()
            pan = (v - 1) * 0.6
            gl, gr = math.sqrt((1 - pan) / 2), math.sqrt((1 + pan) / 2)
            for i in range(n):
                ph += f * d / SR
                ph -= int(ph)
                s = lookup(SAW, ph)
                L[i] += s * gl
                R[i] += s * gr
    # zweipoliger Tiefpass mit zeitlich veraenderlicher Grenzfrequenz + Huellkurve
    for ch in (L, R):
        y1 = y2 = 0.0
        for i in range(n):
            t = i / SR
            if stab:
                fc = cutoff_end + (cutoff - cutoff_end) * math.exp(-t * 7)
                env = min(1.0, t / 0.004) * math.exp(-t * 4.2)
            else:
                fc = cutoff + (cutoff_end - cutoff) * min(1.0, t / dur)
                env = min(1.0, t / attack) * min(1.0, (dur - t) / release)
            a = 1 - math.exp(-2 * math.pi * fc / SR)
            y1 += (ch[i] - y1) * a
            y2 += (y1 - y2) * a
            ch[i] = y2 * env
    return L, R


def rhodes(note, dur):
    n = int(dur * SR)
    f = midi_hz(note)
    L = [0.0] * n
    R = [0.0] * n
    for i in range(n):
        t = i / SR
        # Modulator klingt schneller ab -> heller Anschlag ("Tine"), dann weicher Grundton
        idx = 2.2 * math.exp(-t * 9) + 0.35 * math.exp(-t * 1.2)
        mod = math.sin(2 * math.pi * f * 1.0 * t) * idx
        car = math.sin(2 * math.pi * f * t + mod)
        bell = math.sin(2 * math.pi * f * 7.0 * t) * 0.12 * math.exp(-t * 14)
        env = min(1.0, t / 0.002) * math.exp(-t * 0.9) * min(1.0, (dur - t) / 0.3)
        s = (car + bell) * env
        trem = 1 + 0.08 * math.sin(2 * math.pi * 4.8 * t)
        L[i] = s * trem
        R[i] = s * (2 - trem)
    return L, R


def bass(note, dur):
    n = int(dur * SR)
    f = midi_hz(note)
    L = [0.0] * n
    y = 0.0
    ph = 0.0
    for i in range(n):
        t = i / SR
        ph += f / SR
        ph -= int(ph)
        sub = math.sin(2 * math.pi * ph)
        saw = lookup(SAW, ph)
        y += (saw - y) * (1 - math.exp(-2 * math.pi * 420 / SR))
        s = math.tanh((sub * 0.9 + y * 0.35) * 1.4)
        env = min(1.0, t / 0.008) * min(1.0, (dur - t) / 0.25)
        L[i] = s * env
    return L, L[:]


def main(out):
    random.seed(5)
    out = out.rstrip('/\\') + '/'
    l, r = chord([48, 52, 55, 59, 62], 7.0, 0.6, 1.0, 1800, 3200)
    save(out + 'House_Akkord_Cmaj9.wav', l, r)
    l, r = chord([48, 51, 55, 58, 62], 1.6, 0.0, 0.3, 4500, 500, stab=True, detune=7)
    save(out + 'Deep_Stab_Cm9.wav', l, r)
    l, r = rhodes(60, 4.0)
    save(out + 'Rhodes_C4.wav', l, r)
    l, r = bass(36, 3.0)
    save(out + 'Warmer_Bass_C2.wav', l, r)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
