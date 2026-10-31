"""Erzeugt Natur- und Industrie-Beispieltoene (synthetisch, frei verwendbar):
  Dschungel_Voegel.wav   Vogelrufe (FM-Zwitschern, Triller, Pfiffe) ueber Insekten-Zirpen und Blaetterrauschen
  Erde_Grollen.wav       warmer, tiefer Erdton: C-Quinten-Drone (C1/G1/C2) mit langsamem Grollen
  Industrie_Brummen.wav  warmes Industrie-Brummen: Netzbrummen-Obertoene auf C, metallische Resonanzen,
                         langsamer Maschinentakt (gefiltert, nicht hart)
Aufruf: python make_nature_samples.py <Ordner>
"""
import math
import random
import struct
import sys
import wave

SR = 44100


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


def midi_hz(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def jungle(dur=10.0):
    n = int(dur * SR)
    L = [0.0] * n
    R = [0.0] * n
    # Blaetterrauschen + Insekten (gepulstes, hohes Zirpen)
    lp = bp1 = bp2 = 0.0
    for i in range(n):
        t = i / SR
        x = random.uniform(-1, 1)
        lp += (x - lp) * 0.05
        leaves = (x - lp) * 0.04 * (0.6 + 0.4 * math.sin(t * 0.7))
        chirp = math.sin(2 * math.pi * 4300 * t) * (0.5 + 0.5 * math.sin(2 * math.pi * 31 * t)) ** 6
        chirp *= 0.03 * (0.5 + 0.5 * math.sin(2 * math.pi * 0.23 * t))
        L[i] += leaves + chirp * 0.7
        R[i] += leaves * 0.9 + chirp
    # Vogelrufe: Folgen kurzer FM-Glissandi, zufaellig verteilt, gestimmt auf C-Dur-Pentatonik
    penta = [72, 74, 76, 79, 81, 84, 86, 88, 91, 93]
    t0 = 0.3
    while t0 < dur - 1.0:
        kind = random.random()
        pan = random.uniform(-0.9, 0.9)
        gl, gr = math.sqrt((1 - pan) / 2), math.sqrt((1 + pan) / 2)
        base = midi_hz(random.choice(penta))
        notes = random.randint(2, 6)
        for k in range(notes):
            ln = random.uniform(0.05, 0.18) if kind < 0.6 else random.uniform(0.25, 0.5)
            f0 = base * (1 if kind < 0.6 else 0.8)
            f1 = base * random.choice([1.12, 1.25, 1.5, 0.85])
            s0 = int(t0 * SR)
            ph = 0.0
            for i in range(int(ln * SR)):
                u = i / (ln * SR)
                f = f0 + (f1 - f0) * u
                trill = 1 + 0.03 * math.sin(2 * math.pi * 38 * i / SR) if kind > 0.8 else 1
                ph += f * trill / SR
                env = math.sin(math.pi * u) ** 2
                s = math.sin(2 * math.pi * ph + 0.6 * math.sin(2 * math.pi * ph * 2)) * env * 0.22
                j = s0 + i
                if j < n:
                    L[j] += s * gl
                    R[j] += s * gr
            t0 += ln + random.uniform(0.02, 0.08)
        t0 += random.uniform(0.3, 1.2)
    return L, R


def earth(dur=8.0):
    n = int(dur * SR)
    L = [0.0] * n
    R = [0.0] * n
    notes = [24, 31, 36, 43]     # C1 G1 C2 G2
    phs = [random.random() for _ in notes]
    lp = 0.0
    y1 = y2 = 0.0
    for i in range(n):
        t = i / SR
        s = 0.0
        for k, nn in enumerate(notes):
            f = midi_hz(nn) * (1 + 0.002 * math.sin(t * (0.3 + k * 0.11)))
            phs[k] += f / SR
            phs[k] -= int(phs[k])
            p = phs[k]
            s += (math.sin(2 * math.pi * p) + 0.35 * math.sin(4 * math.pi * p) + 0.15 * math.sin(6 * math.pi * p)) / (1 + k * 0.5)
        # Grollen: tiefpassgefiltertes Rauschen, langsam pulsierend
        lp += (random.uniform(-1, 1) - lp) * 0.004
        rumble = lp * 3.0 * (0.6 + 0.4 * math.sin(t * 0.9))
        x = math.tanh((s * 0.35 + rumble) * 1.2)
        a = 1 - math.exp(-2 * math.pi * (300 + 200 * math.sin(t * 0.4)) / SR)
        y1 += (x - y1) * a
        y2 += (y1 - y2) * a
        env = min(1.0, t / 0.8) * min(1.0, (dur - t) / 1.0)
        L[i] = y2 * env
        R[i] = y2 * env * (0.95 + 0.05 * math.sin(t * 1.3))
    return L, R


def industry(dur=8.0):
    n = int(dur * SR)
    L = [0.0] * n
    R = [0.0] * n
    f0 = midi_hz(36)               # C2 als Brumm-Grundton (warm, stimmbar)
    res = [(midi_hz(67) * 1.0, 0.004), (midi_hz(79) * 1.01, 0.003), (midi_hz(88) * 0.99, 0.002)]
    rs = [[0.0, 0.0] for _ in res]
    ph = 0.0
    lp = 0.0
    for i in range(n):
        t = i / SR
        ph += f0 / SR
        ph -= int(ph)
        hum = sum(math.sin(2 * math.pi * ph * h) / h ** 1.2 for h in range(1, 9))
        # Maschinentakt: weiche Schlaege alle 0,5 s (120 BPM Achtel), tiefpassgefiltert
        beat = (t % 0.5) / 0.5
        hit = math.exp(-beat * 18) * random.uniform(-1, 1)
        lp += (hit - lp) * 0.08
        # metallische Resonanzen, vom Takt angeregt (stimmhaft: G4, G5, E6)
        metal = 0.0
        for k, (fr, damp) in enumerate(res):
            w = 2 * math.pi * fr / SR
            r = 1 - damp
            y = lp * 0.5 + 2 * r * math.cos(w) * rs[k][0] - r * r * rs[k][1]
            rs[k][1], rs[k][0] = rs[k][0], y
            metal += y * (0.02 / (k + 1))
        x = math.tanh(hum * 0.25 * (0.85 + 0.15 * math.sin(t * 0.5)) + lp * 0.6 + metal)
        env = min(1.0, t / 0.4) * min(1.0, (dur - t) / 0.8)
        L[i] = x * env
        R[i] = x * env * 0.92 + metal * 0.3 * env
    return L, R


def waterfall(dur=10.0):
    n = int(dur * SR)
    L = [0.0] * n
    R = [0.0] * n
    lpl = lpr = 0.0
    bl = br = 0.0
    for i in range(n):
        t = i / SR
        xl, xr = random.uniform(-1, 1), random.uniform(-1, 1)
        lpl += (xl - lpl) * 0.03          # tiefes Tosen
        lpr += (xr - lpr) * 0.03
        bl += (xl - bl) * 0.35            # helles Rauschen
        br += (xr - br) * 0.35
        swell = 0.8 + 0.2 * math.sin(t * 0.37) * math.sin(t * 0.11 + 1)
        L[i] = (lpl * 2.2 + (xl - bl) * 0.25 + bl * 0.15) * swell
        R[i] = (lpr * 2.2 + (xr - br) * 0.25 + br * 0.15) * swell
    # Tropfen/Blubbern: kurze, hohe, abklingende Sinus-Pings auf Pentatonik (dezent)
    penta = [84, 86, 88, 91, 93, 96]
    for _ in range(int(dur * 9)):
        t0 = random.uniform(0, dur - 0.2)
        f = midi_hz(random.choice(penta)) * random.uniform(0.98, 1.02)
        pan = random.uniform(-1, 1)
        gl, gr = math.sqrt((1 - pan) / 2), math.sqrt((1 + pan) / 2)
        s0 = int(t0 * SR)
        for j in range(int(0.12 * SR)):
            u = j / SR
            fr = f * (1 + 0.6 * math.exp(-u * 60))      # Blubbern: Tonhoehe faellt kurz
            v = math.sin(2 * math.pi * fr * u) * math.exp(-u * 40) * 0.12
            if s0 + j < n:
                L[s0 + j] += v * gl
                R[s0 + j] += v * gr
    for i in range(n):
        env = min(1.0, i / SR / 0.5) * min(1.0, (dur - i / SR) / 0.8)
        L[i] *= env
        R[i] *= env
    return L, R


def bright_pad(dur=8.0):
    n = int(dur * SR)
    L = [0.0] * n
    R = [0.0] * n
    notes = [60, 67, 74, 76, 79]      # Cadd9 hell: C4 G4 D5 E5 G5
    for k, nn in enumerate(notes):
        for v in range(3):
            f = midi_hz(nn) * 2 ** ((v - 1) * 6 / 1200)
            ph = random.random()
            pan = (v - 1) * 0.7
            gl, gr = math.sqrt((1 - pan) / 2), math.sqrt((1 + pan) / 2)
            amp = 0.5 / (1 + k * 0.3)
            for i in range(n):
                ph += f / SR
                ph -= int(ph)
                tri = 1 - 4 * abs(ph - 0.5)
                s = (math.sin(2 * math.pi * ph) * 0.7 + tri * 0.3) * amp
                L[i] += s * gl
                R[i] += s * gr
    for i in range(n):
        t = i / SR
        env = min(1.0, t / 1.0) * min(1.0, (dur - t) / 1.2) * (0.9 + 0.1 * math.sin(t * 0.8))
        L[i] *= env
        R[i] *= env
    return L, R


def main(out):
    random.seed(17)
    out = out.rstrip('/\\') + '/'
    l, r = jungle()
    save(out + 'Dschungel_Voegel.wav', l, r)
    l, r = earth()
    save(out + 'Erde_Grollen.wav', l, r)
    l, r = industry()
    save(out + 'Industrie_Brummen.wav', l, r)
    l, r = waterfall()
    save(out + 'Wasserfall.wav', l, r)
    l, r = bright_pad()
    save(out + 'Helle_Flaeche_Cadd9.wav', l, r)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
