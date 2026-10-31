"""Erzeugt realistische Instrumenten-Samples (synthetisch, frei verwendbar) mit physikalischen Modellen:
  Konzertgitarre_C3   gezupfte Nylonsaite (Karplus-Strong, zwei Schwingungsebenen, Zupfposition, Korpus)
  Harfe_C4            Harfensaite, weich gezupft, lang ausklingend, Resonanzboden
  Kontrabass_Pizzicato_C2  tiefe Saite gezupft, Korpusresonanzen
  Marimba_C4          Palisanderstab (Moden 1 : 4 : 9,9) mit Resonanzrohr und Schlaegelkontakt
  Roehrenglocke_C5    Rohrglocke (freie Balkenmoden, Schwebungs-Paare, lange Abklingzeit)
  Kalimba_C5          Metallzunge (eingespannter Balken) mit Kasten-Resonanz
  Steeldrum_C4        Steelpan-Feld (harmonisch gestimmte Moden, Anschlag-Tonhoehenknick)
  Klarinette_C4       Waveguide: zylindrische Bohrung + Rohrblatt (nach Smith/STK), Atemgeraeusch
Aufruf: python make_instruments.py <Ordner>"""
import math, random, struct, sys, wave

SR = 44100
TWO_PI = 2 * math.pi


def midi_hz(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def save(path, left, right, peak=0.89):
    m = max(max(abs(v) for v in left), max(abs(v) for v in right), 1e-9)
    g = peak / m
    with wave.open(path, 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<hh', int(max(-1, min(1, l * g)) * 32767),
                                           int(max(-1, min(1, r * g)) * 32767)) for l, r in zip(left, right)))


class Biquad:
    """RBJ-Biquad (Bandpass konstante Spitze / Tiefpass / Hochpass / Peak)"""
    def __init__(self, kind, f, q, gain_db=0.0):
        w = TWO_PI * f / SR
        cs, sn = math.cos(w), math.sin(w)
        al = sn / (2 * q)
        A = 10 ** (gain_db / 40)
        if kind == 'bp':
            b0, b1, b2, a0, a1, a2 = al, 0, -al, 1 + al, -2 * cs, 1 - al
        elif kind == 'lp':
            b0, b1, b2, a0, a1, a2 = (1 - cs) / 2, 1 - cs, (1 - cs) / 2, 1 + al, -2 * cs, 1 - al
        elif kind == 'hp':
            b0, b1, b2, a0, a1, a2 = (1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + al, -2 * cs, 1 - al
        else:  # peak
            b0, b1, b2, a0, a1, a2 = 1 + al * A, -2 * cs, 1 - al * A, 1 + al / A, -2 * cs, 1 - al / A
        self.b = (b0 / a0, b1 / a0, b2 / a0)
        self.a = (a1 / a0, a2 / a0)
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def run(self, x):
        b0, b1, b2 = self.b; a1, a2 = self.a
        y = b0 * x + b1 * self.x1 + b2 * self.x2 - a1 * self.y1 - a2 * self.y2
        self.x2, self.x1, self.y2, self.y1 = self.x1, x, self.y1, y
        return y

    def block(self, xs):
        return [self.run(x) for x in xs]


def fade_out(xs, sec):
    n = len(xs); k = int(sec * SR)
    for i in range(max(0, n - k), n):
        xs[i] *= (n - i) / k
    return xs


def room(mono, width=0.5, amount=0.12, seed=1):
    """kleiner Raum: einige fruehe Reflexionen je Seite (dekorreliert) -> natuerliches Stereo, kein Hall"""
    rnd = random.Random(seed)
    n = len(mono)
    L = list(mono); R = list(mono)
    for side in (L, R):
        for _ in range(7):
            d = int(rnd.uniform(0.004, 0.028) * SR)
            g = amount * rnd.uniform(0.4, 1.0) * (1 if rnd.random() < 0.7 else -1)
            for i in range(n - 1, d - 1, -1):
                side[i] += mono[i - d] * g
    # Breite: Mitte/Seite
    for i in range(n):
        m = (L[i] + R[i]) * 0.5; s = (L[i] - R[i]) * 0.5 * width * 2
        L[i], R[i] = m + s, m - s
    return L, R


# ------------------------------------------------------------------ gezupfte Saite
def pluck_string(f0, dur, t60, bright, pluck_pos, body, seed, soft=0.5, detune_cent=0.6, noise_amt=0.02):
    """Karplus-Strong erweitert: zwei Polarisationen (leicht verstimmt, verschieden gedaempft),
    Feinstimmung per Allpass, frequenzabhaengige Daempfung, Anregung mit Zupfposition-Kammfilter,
    Korpus als Resonanzfilterbank."""
    rnd = random.Random(seed)
    n = int(dur * SR)
    out = [0.0] * n
    for pol, (dc, g_t60, lvl) in enumerate([(0.0, t60, 1.0), (detune_cent, t60 * 0.6, 0.55)]):
        f = f0 * 2 ** (dc / 1200)
        P = SR / f - 0.5                          # -0.5: Laufzeit des Mittelwert-Tiefpasses
        N = int(P); frac = P - N
        if frac < 0.1:
            N -= 1; frac += 1
        ap_c = (1 - frac) / (1 + frac)             # Allpass fuer den Bruchteil
        # Anregung: Rauschen, weich (Fingerkuppe) tiefpassgefiltert, Kammfilter = Zupfposition
        ex = [rnd.uniform(-1, 1) for _ in range(N)]
        lp = 0.0
        for i in range(N):
            lp += (ex[i] - lp) * (1 - soft * 0.85)
            ex[i] = lp
        d = max(1, int(pluck_pos * N))
        ex = [ex[i] - (ex[i - d] if i >= d else 0) for i in range(N)]
        m = sum(ex) / N
        ex = [v - m for v in ex]
        buf = ex[:]
        g = 10 ** (-3 / (g_t60 * f))               # Verlust je Umlauf fuer T60
        a = 0.5 * (1 - bright) + 0.5 * bright * 0.0
        idx = 0; prev = 0.0; ap_x1 = ap_y1 = 0.0
        for i in range(n):
            cur = buf[idx]
            # Schleifenfilter: Mischung aus Mittelwert (dunkel) und direkt (hell)
            y = g * (bright * cur + (1 - bright) * 0.5 * (cur + prev))
            prev = cur
            ap = ap_c * y + ap_x1 - ap_c * ap_y1   # fraktionale Verzoegerung
            ap_x1, ap_y1 = y, ap
            buf[idx] = ap
            idx += 1
            if idx >= N:
                idx = 0
            out[i] += cur * lvl
    # Fingergeraeusch beim Anschlag
    for i in range(int(0.012 * SR)):
        out[i] += rnd.uniform(-1, 1) * noise_amt * (1 - i / (0.012 * SR))
    # Korpus: Resonanzen + Direktanteil
    res = [Biquad('bp', fr, q) for fr, q, _ in body]
    gains = [g for _, _, g in body]
    y = []
    for x in out:
        s = x
        for b, gg in zip(res, gains):
            s += b.run(x) * gg
        y.append(s)
    return y


def gitarre(out):
    f = midi_hz(48)                                # C3
    x = pluck_string(f, 6.0, 3.6, 0.15, 0.18, [(98, 6, 1.2), (205, 9, 0.9), (395, 10, 0.5), (2600, 1.5, 0.25)],
                     seed=11, soft=0.55, noise_amt=0.03)
    hp = Biquad('hp', 60, 0.7)
    x = fade_out(hp.block(x), 0.4)
    L, R = room(x, 0.45, 0.1, seed=3)
    save(out + '/Konzertgitarre_C3.wav', L, R)


def harfe(out):
    f = midi_hz(60)
    x = pluck_string(f, 7.0, 5.5, 0.08, 0.32, [(180, 3, 0.6), (420, 4, 0.4), (1100, 2, 0.2)],
                     seed=12, soft=0.7, noise_amt=0.012, detune_cent=0.4)
    # leichtes Mitschwingen der Oktave (Nachbarsaiten)
    y = pluck_string(f * 2, 7.0, 4.0, 0.05, 0.5, [], seed=13, soft=0.9, noise_amt=0, detune_cent=0.3)
    x = [a + 0.04 * b * min(1.0, i / (0.3 * SR)) for i, (a, b) in enumerate(zip(x, y))]
    x = fade_out(x, 0.5)
    L, R = room(x, 0.6, 0.12, seed=4)
    save(out + '/Harfe_C4.wav', L, R)


def kontrabass(out):
    f = midi_hz(36)                                # C2
    x = pluck_string(f, 4.0, 1.6, 0.04, 0.22, [(58, 5, 1.6), (112, 7, 1.0), (235, 8, 0.4)],
                     seed=14, soft=0.85, noise_amt=0.02, detune_cent=0.8)
    lp = Biquad('lp', 1800, 0.7)
    x = fade_out(lp.block(x), 0.4)
    L, R = room(x, 0.3, 0.08, seed=5)
    save(out + '/Kontrabass_Pizzicato_C2.wav', L, R)


# ------------------------------------------------------------------ Modalsynthese
def modal(modes, dur, seed, attack_noise=0.0, noise_lp=0.3, noise_len=0.004, pitch_drop=0.0):
    """modes: (Frequenz, Amplitude, T60, Schwebung Hz). Jede Mode = gedaempfter Sinus (ggf. als Paar)."""
    rnd = random.Random(seed)
    n = int(dur * SR)
    out = [0.0] * n
    for f, a, t60, beat in modes:
        if f >= SR * 0.45:
            continue
        k = math.log(1000) / (t60 * SR)
        for sub, bf in ((0, 0.0), (1, beat)) if beat else ((0, 0.0),):
            ph = rnd.random() * 0.2
            amp = a * (0.5 if beat else 1.0)
            ff = f + bf
            for i in range(n):
                e = math.exp(-k * i)
                if e < 1e-5:
                    break
                fi = ff * (1 + pitch_drop * math.exp(-i / (0.03 * SR)))
                ph += fi / SR
                out[i] += amp * e * math.sin(TWO_PI * ph)
    if attack_noise:
        m = int(noise_len * SR); lp = 0.0
        for i in range(m):
            lp += (rnd.uniform(-1, 1) - lp) * noise_lp
            out[i] += lp * attack_noise * math.sin(math.pi * i / m)
    return out


def marimba(out):
    f = midi_hz(60)
    modes = [(f, 1.0, 1.5, 0), (f * 3.93, 0.32, 0.55, 0), (f * 9.83, 0.09, 0.18, 0),
             (f * 2.71, 0.02, 0.3, 0)]
    x = modal(modes, 3.5, seed=21, attack_noise=0.35, noise_lp=0.25, noise_len=0.003)
    # Resonanzrohr: verstaerkt die Grundfrequenz, spricht etwas verzoegert an
    rnd = random.Random(2)
    k = math.log(1000) / (1.9 * SR)
    for i in range(len(x)):
        x[i] += 0.45 * math.exp(-k * i) * (1 - math.exp(-i / (0.012 * SR))) * math.sin(TWO_PI * f * i / SR + 0.4)
    x = fade_out(x, 0.3)
    L, R = room(x, 0.5, 0.1, seed=6)
    save(out + '/Marimba_C4.wav', L, R)


def roehrenglocke(out):
    strike = midi_hz(72)                           # gehoerter Schlagton C5 ~ Mode 4 / 2
    f1 = strike * 2 / 8.933
    ratios = [1, 2.756, 5.404, 8.933, 13.344, 18.64, 26.0]
    amps = [0.25, 0.55, 0.9, 1.0, 0.8, 0.55, 0.25]
    t60s = [9, 8, 7, 6, 4.5, 3.2, 2.0]
    modes = [(f1 * r, a, t, 0.25 + 0.15 * j) for j, (r, a, t) in enumerate(zip(ratios, amps, t60s))]
    x = modal(modes, 9.0, seed=22, attack_noise=0.25, noise_lp=0.7, noise_len=0.002)
    x = fade_out(x, 0.8)
    L, R = room(x, 0.7, 0.14, seed=7)
    save(out + '/Roehrenglocke_C5.wav', L, R)


def kalimba(out):
    f = midi_hz(72)
    modes = [(f, 1.0, 2.6, 0.15), (f * 6.27, 0.22, 0.35, 0), (f * 17.55, 0.05, 0.08, 0)]
    x = modal(modes, 3.5, seed=23, attack_noise=0.2, noise_lp=0.5, noise_len=0.003)
    box = Biquad('bp', 310, 4)
    x = [v + box.run(v) * 0.8 for v in x]
    # leichtes Schnarren der Zunge am Steg (sehr dezent, nur im Anschlag)
    for i in range(int(0.08 * SR)):
        x[i] += 0.03 * math.sin(TWO_PI * f * 2 * i / SR) * (1 if math.sin(TWO_PI * f * i / SR) > 0.6 else 0) * (1 - i / (0.08 * SR))
    x = fade_out(x, 0.3)
    L, R = room(x, 0.5, 0.11, seed=8)
    save(out + '/Kalimba_C5.wav', L, R)


def steeldrum(out):
    f = midi_hz(60)
    modes = [(f, 1.0, 2.6, 0.4), (f * 2.0, 0.85, 2.0, 0.6), (f * 3.0, 0.35, 1.3, 0),
             (f * 4.05, 0.12, 0.5, 0), (f * 5.1, 0.05, 0.3, 0), (midi_hz(67) * 2, 0.02, 1.0, 0)]
    x = modal(modes, 3.5, seed=24, attack_noise=0.3, noise_lp=0.6, noise_len=0.002, pitch_drop=0.012)
    x = fade_out(x, 0.3)
    L, R = room(x, 0.55, 0.12, seed=9)
    save(out + '/Steeldrum_C4.wav', L, R)


# ------------------------------------------------------------------ Klarinette (Waveguide)
def klarinette(out):
    rnd = random.Random(31)
    f = midi_hz(60)
    dur = 5.0
    n = int(dur * SR)
    D = SR / f * 0.5 - 1.5 + 0.5
    N = int(D); frac = D - N
    buf = [0.0] * (N + 2)
    w = 0
    lp_prev = 0.0
    nlp = 0.0
    out_s = [0.0] * n
    for i in range(n):
        t = i / SR
        # Atemdruck: Einschwingen 60 ms, leichtes Atmen + Vibrato kaum (Klarinette spielt meist ohne)
        env = min(1.0, t / 0.06) * (1 if t < dur - 0.35 else max(0.0, (dur - t) / 0.35))
        nlp += (rnd.uniform(-1, 1) - nlp) * 0.3
        breath = env * (0.62 + 0.012 * math.sin(TWO_PI * 0.7 * t)) + nlp * 0.025 * env
        # Delay-Ausgang mit linearer Interpolation
        r = w - N
        a = buf[r % len(buf)]; b = buf[(r - 1) % len(buf)]
        dl = a + (b - a) * frac
        # Reflexion am offenen Ende: invertiert + Tiefpass (Einnull)
        refl = -0.95 * 0.5 * (dl + lp_prev)
        lp_prev = dl
        pd = refl - breath
        reed = max(-1.0, min(1.0, 0.7 - 0.3 * pd))
        v = breath + pd * reed
        buf[w % len(buf)] = v
        w += 1
        out_s[i] = dl
    # Abstrahlung: Hochpass (Schallbecher), dezente Formanten des Holzes
    hp = Biquad('hp', 120, 0.7)
    pk1 = Biquad('pk', 1500, 1.2, 3)
    lp = Biquad('lp', 6000, 0.7)
    x = [lp.run(pk1.run(hp.run(v))) for v in out_s]
    # Atemgeraeusch (hoerbar, leise)
    nn = 0.0
    for i in range(n):
        nn += (rnd.uniform(-1, 1) - nn) * 0.5
        x[i] += nn * 0.006 * min(1.0, i / (0.06 * SR))
    L, R = room(x, 0.35, 0.1, seed=10)
    save(out + '/Klarinette_C4.wav', L, R)


if __name__ == '__main__':
    o = sys.argv[1] if len(sys.argv) > 1 else '.'
    for fn in (gitarre, harfe, kontrabass, marimba, roehrenglocke, kalimba, steeldrum, klarinette):
        fn(o)
        print('ok', fn.__name__)
