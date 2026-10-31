"""Erzeugt die Beispieltoene fuer GranularSynth (Stereo, 44,1 kHz, 16 Bit).

Reines Python ohne Zusatzpakete. Aufruf:
    python make_samples.py <Zielordner>
Alle Klaenge sind synthetisch erzeugt (keine fremden Aufnahmen) und frei verwendbar.
"""
import math
import random
import struct
import sys
import wave

SR = 44100
TWO_PI = 2 * math.pi


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


class OnePole:
    """Einfacher Tiefpass fuer Klangfarbe."""
    def __init__(self):
        self.y = 0.0

    def run(self, x, coef):
        self.y += (x - self.y) * coef
        return self.y


def choir(path):
    """Chor 'Aah' - mehrere verstimmte Stimmen mit Formanten, langsame Vibrati."""
    secs = 6.0
    n = int(SR * secs)
    left, right = [0.0] * n, [0.0] * n
    formants = [(730, 1.0), (1090, 0.5), (2440, 0.25)]       # Vokal a
    notes = [57, 60, 64, 69]                                  # Am-Akkord
    random.seed(7)
    for vi, note in enumerate(notes):
        for k in range(3):                                    # 3 Saenger je Stimme
            f0 = midi_hz(note) * (1 + random.uniform(-0.006, 0.006))
            vib_rate = random.uniform(4.6, 5.8)
            vib_ph = random.uniform(0, TWO_PI)
            pan = random.uniform(-0.8, 0.8)
            harmonics = []
            h = 1
            while h * f0 < 5000:
                a = sum(amp * math.exp(-((h * f0 - fc) / 120.0) ** 2) for fc, amp in formants)
                harmonics.append((h, a + 0.02 / h))
                h += 1
            ph = 0.0
            for i in range(n):
                t = i / SR
                f = f0 * (1 + 0.008 * math.sin(TWO_PI * vib_rate * t + vib_ph))
                ph += f / SR
                s = 0.0
                for hh, a in harmonics[:24]:
                    s += a * math.sin(TWO_PI * hh * ph)
                env = min(1.0, t / 1.2) * min(1.0, (secs - t) / 1.0)
                v = s * env
                left[i] += v * (1 - pan) * 0.5
                right[i] += v * (1 + pan) * 0.5
    save(path, left, right)


def bells(path):
    """Glasglocken - unharmonische Teiltoene, mehrere Anschlaege, langes Ausklingen."""
    secs = 7.0
    n = int(SR * secs)
    left, right = [0.0] * n, [0.0] * n
    ratios = [(1.0, 1.0, 3.0), (2.76, 0.6, 2.2), (5.40, 0.4, 1.4), (8.93, 0.25, 0.9), (13.34, 0.15, 0.6)]
    hits = [(0.0, 76, -0.5), (0.9, 79, 0.4), (1.8, 83, -0.2), (2.7, 88, 0.6), (4.0, 71, 0.0)]
    for start, note, pan in hits:
        f0 = midi_hz(note)
        s0 = int(start * SR)
        for ratio, amp, decay in ratios:
            f = f0 * ratio
            if f > 16000:
                continue
            for i in range(s0, n):
                t = (i - s0) / SR
                v = amp * math.exp(-t / decay) * math.sin(TWO_PI * f * t)
                left[i] += v * (1 - pan) * 0.5
                right[i] += v * (1 + pan) * 0.5
    save(path, left, right)


def strings(path):
    """Streicherflaeche - Saegezahn-Ensemble, Klang oeffnet sich langsam (Tiefpass)."""
    secs = 8.0
    n = int(SR * secs)
    left, right = [0.0] * n, [0.0] * n
    random.seed(3)
    chord = [45, 52, 57, 60, 64]
    for note in chord:
        for k in range(4):
            f = midi_hz(note) * (1 + random.uniform(-0.004, 0.004))
            pan = random.uniform(-0.9, 0.9)
            lp = OnePole()
            ph = random.random()
            for i in range(n):
                t = i / SR
                ph += f / SR
                ph -= math.floor(ph)
                saw = 2 * ph - 1
                coef = 0.02 + 0.25 * (t / secs) ** 1.5            # Filter oeffnet sich
                v = lp.run(saw, coef) * min(1.0, t / 1.5) * min(1.0, (secs - t) / 1.2)
                left[i] += v * (1 - pan) * 0.5
                right[i] += v * (1 + pan) * 0.5
    save(path, left, right)


def plucks(path):
    """Gezupftes Arpeggio (Karplus-Strong) - perkussiv, gut fuer Rhythmus-Grains."""
    secs = 6.0
    n = int(SR * secs)
    left, right = [0.0] * n, [0.0] * n
    random.seed(11)
    seq = [45, 52, 57, 60, 64, 60, 57, 52, 41, 48, 53, 57, 60, 57, 53, 48]
    step = 0.32
    for k, note in enumerate(seq):
        start = int(k * step * SR)
        period = int(SR / midi_hz(note))
        buf = [random.uniform(-1, 1) for _ in range(period)]
        pan = math.sin(k * 0.9) * 0.6
        idx = 0
        for i in range(start, min(n, start + int(2.5 * SR))):
            a = buf[idx]
            b = buf[(idx + 1) % period]
            buf[idx] = 0.996 * 0.5 * (a + b)
            idx = (idx + 1) % period
            left[i] += a * (1 - pan) * 0.5
            right[i] += a * (1 + pan) * 0.5
    save(path, left, right)


def rain(path):
    """Regen-Textur - gefilterte Tropfen und Rauschen, raeumlich verteilt."""
    secs = 6.0
    n = int(SR * secs)
    left, right = [0.0] * n, [0.0] * n
    random.seed(5)
    lpl, lpr = OnePole(), OnePole()
    for i in range(n):                                       # leises Grundrauschen
        left[i] = lpl.run(random.uniform(-1, 1), 0.08) * 0.25
        right[i] = lpr.run(random.uniform(-1, 1), 0.08) * 0.25
    for _ in range(420):                                     # Tropfen: kurze, absinkende Sinusblips
        s0 = random.randint(0, n - 4000)
        f = random.uniform(900, 4200)
        pan = random.uniform(-1, 1)
        amp = random.uniform(0.2, 0.9)
        ph = 0.0
        for j in range(3000):
            t = j / SR
            ph += f * (1 - 0.6 * min(1.0, t * 40)) / SR
            v = amp * math.exp(-t * 60) * math.sin(TWO_PI * ph)
            left[s0 + j] += v * (1 - pan) * 0.5
            right[s0 + j] += v * (1 + pan) * 0.5
    save(path, left, right)


def keys(path):
    """E-Piano-Akkorde - glockiger FM-Ton mit Anschlagsgeraeusch."""
    secs = 7.0
    n = int(SR * secs)
    left, right = [0.0] * n, [0.0] * n
    chords = [(0.0, [57, 60, 64, 67]), (1.75, [53, 57, 60, 64]), (3.5, [48, 52, 55, 59]), (5.25, [55, 59, 62, 65])]
    random.seed(2)
    for start, notes in chords:
        s0 = int(start * SR)
        for vi, note in enumerate(notes):
            f = midi_hz(note)
            pan = (vi - 1.5) * 0.35
            for i in range(s0, n):
                t = (i - s0) / SR
                index = 2.2 * math.exp(-t * 3.0)                 # FM-Index klingt ab -> weicher
                mod = math.sin(TWO_PI * f * t) * index
                v = math.sin(TWO_PI * f * t + mod) * math.exp(-t * 0.9)
                if t < 0.01:
                    v += random.uniform(-0.3, 0.3) * (1 - t / 0.01)   # Anschlag
                left[i] += v * (1 - pan) * 0.5
                right[i] += v * (1 + pan) * 0.5
    save(path, left, right)


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    print('Erzeuge Beispieltoene in ' + out)
    choir(out + '/Chor_Aah.wav')
    bells(out + '/Glasglocken.wav')
    strings(out + '/Streicherflaeche.wav')
    plucks(out + '/Gezupftes_Arpeggio.wav')
    rain(out + '/Regen_Textur.wav')
    keys(out + '/E-Piano_Akkorde.wav')
    print('fertig')
