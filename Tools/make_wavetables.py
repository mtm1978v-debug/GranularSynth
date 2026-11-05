"""Erzeugt Beispiel-Wavetables (synthetisch, frei verwendbar) im Serum-Format: je Frame 2048 Punkte,
16 Frames hintereinander, Mono, 16 Bit. Der Oszillator laedt sie ueber "Wavetable laden ...".
  WT_Saege_zu_Rechteck.wav  Saegezahn -> Rechteck (Pulsbreite schliesst sich)
  WT_Formant_Vokale.wav     Obertoene mit wanderndem Formant a - e - i - o - u (sprechender Bass)
  WT_FM_Wachsend.wav        Sinus -> harte FM (Index 0 .. 8), fuer knurrende Techno-Baesse
Aufruf: python make_wavetables.py <Ordner>"""
import math, struct, sys, wave

N = 2048
FRAMES = 16
HARM = 200      # Obertoene je Frame (bandbegrenzt; der Oszillator begrenzt beim Spielen weiter)


def additive(amps):
    """eine Periode aus Sinus-Obertoenen: amps[k] fuer Oberton k+1"""
    out = []
    for i in range(N):
        w = 2 * math.pi * i / N
        s = 0.0
        for k, a in enumerate(amps):
            if a:
                s += a * math.sin((k + 1) * w)
        out.append(s)
    return out


def norm(x):
    m = max(abs(v) for v in x) or 1.0
    return [v / m * 0.95 for v in x]


def saw_to_square(f):
    t = f / (FRAMES - 1)
    amps = []
    for k in range(1, HARM + 1):
        saw = 1.0 / k
        sq = (1.0 / k) if k % 2 else 0.0
        amps.append(saw * (1 - t) + sq * t * 1.27)
    return additive(amps)


VOWELS = [(800, 1150), (400, 1900), (300, 2300), (450, 800), (330, 700)]   # a e i o u (F1, F2 in Hz)


def formant(f):
    # Grundton gedacht bei 110 Hz: Oberton k liegt bei k * 110 Hz
    pos = f / (FRAMES - 1) * (len(VOWELS) - 1)
    i0 = min(int(pos), len(VOWELS) - 2)
    t = pos - i0
    f1 = VOWELS[i0][0] * (1 - t) + VOWELS[i0 + 1][0] * t
    f2 = VOWELS[i0][1] * (1 - t) + VOWELS[i0 + 1][1] * t
    amps = []
    for k in range(1, HARM + 1):
        hz = k * 110.0
        g = math.exp(-((hz - f1) / 160) ** 2) + 0.6 * math.exp(-((hz - f2) / 220) ** 2) + 0.02 / k
        amps.append(g)
    return additive(amps)


def fm_grow(f):
    idx = 8.0 * (f / (FRAMES - 1)) ** 1.5
    out = []
    for i in range(N):
        w = 2 * math.pi * i / N
        out.append(math.sin(w + idx * math.sin(2 * w)))   # Traeger 1, Modulator 2: hohl und knurrend
    return out


def write(path, frames):
    data = b''.join(struct.pack('<h', int(max(-1, min(1, v)) * 32767)) for fr in frames for v in fr)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(data)


def main(out):
    for name, fn in (('WT_Saege_zu_Rechteck.wav', saw_to_square), ('WT_Formant_Vokale.wav', formant),
                     ('WT_FM_Wachsend.wav', fm_grow)):
        write(out.rstrip('/\\') + '/' + name, [norm(fn(f)) for f in range(FRAMES)])
        print(name)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
