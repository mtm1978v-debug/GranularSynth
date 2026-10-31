"""Erzeugt Kirchenorgel_C3.wav (synthetisch, frei verwendbar): Pfeifenorgel-Register 16' 8' 4' 2 2/3' 2'
mit leichter Schwebung, Winddruck-Rauschen und weichem Einschwingen. Aufruf: python make_orgel.py <Ordner>"""
import math, random, struct, sys, wave
SR = 44100
def main(out):
    random.seed(5)
    dur = 7.0
    n = int(dur * SR)
    f0 = 130.8128                       # C3
    # (Fussmass-Faktor, Pegel, Verstimmung in Cent)
    ranks = [(0.5, 0.45, 0), (1, 1.0, 0), (1, 0.6, 4), (2, 0.55, -3), (3, 0.22, 2), (4, 0.3, 0), (6, 0.08, 1), (8, 0.1, -2)]
    L = [0.0] * n; R = [0.0] * n
    for k, (m, a, c) in enumerate(ranks):
        f = f0 * m * 2 ** (c / 1200)
        ph = random.random(); pan = (k % 3 - 1) * 0.4
        gl, gr = math.sqrt((1 - pan) / 2), math.sqrt((1 + pan) / 2)
        att = 0.06 + 0.04 * k            # hoehere Pfeifen sprechen etwas spaeter an
        for i in range(n):
            t = i / SR
            ph += f * (1 + 0.0008 * math.sin(t * 5.1 + k)) / SR
            ph -= int(ph)
            p = ph
            s = (math.sin(2 * math.pi * p) + 0.12 * math.sin(4 * math.pi * p)) * a * min(1.0, t / att)
            L[i] += s * gl; R[i] += s * gr
    lp = 0.0
    for i in range(n):
        t = i / SR
        lp += (random.uniform(-1, 1) - lp) * 0.2
        wind = lp * 0.03 * (1 + 2 * math.exp(-t * 8))
        env = min(1.0, (dur - t) / 0.6)
        L[i] = (L[i] + wind) * env; R[i] = (R[i] + wind * 0.9) * env
    m = max(max(map(abs, L)), max(map(abs, R)))
    g = 0.89 / m
    with wave.open(out + "/Kirchenorgel_C3.wav", "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<hh', int(l * g * 32767), int(r * g * 32767)) for l, r in zip(L, R)))
if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
