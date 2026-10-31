"""Uebersetzungen pruefen: welche Texte der Oberflaeche fehlen in den Sprachdateien (Sprachen/*.txt)?

Quellen der Texte (deutsch = Schluessel):
  1. Laufzeit: der Pruefstand (GranularHost.exe -bench) baut die Oberflaeche auf und schreibt alle Texte, die
     durch Tr laufen, nach bin/<Plattform>/lang_fehlend_alle.txt
  2. Quelltext: jedes Tr('...') in Source/ (auch Texte, die nur in seltenen Faellen erscheinen)
  3. Tooltips: Source/UI/Granular.Hints.pas (erzeugt aus der Reglertabelle der Hilfe)
Ausgabe je Sprache: Sprachen/_fehlend_<Kuerzel>.txt (Schluessel<TAB>, zum Ergaenzen); Rueckgabewert 1, wenn etwas
fehlt - deploy.bat bricht dann ab. Aufruf: python Tools/lang_check.py [--alle]  (--alle: Gesamtliste nach
Sprachen/_alle_texte.txt, z.B. als Vorlage fuer eine neue Sprache).

Uebersetzte Dokumente (Hilfe, Liesmich, Lernpfad): Sprachen/_stand_<Kuerzel>.txt merkt sich einen Fingerabdruck
der deutschen Vorlage zum Zeitpunkt der Uebersetzung. Aendert sich die Vorlage, meldet das Skript das Dokument
als veraltet. Nach dem Nachziehen der Uebersetzung:  python Tools/lang_check.py --stand  (Fingerabdruecke neu)."""
import glob, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
LANG = os.path.join(ROOT, 'Sprachen')
LIT = r"'(?:[^']|'')*'"
TR = re.compile(r"\bTr\(\s*(" + LIT + r"(?:\s*\+\s*" + LIT + r")*)\s*\)", re.S)


def has_letter(s):
    return re.search(r'[A-Za-zÄÖÜäöüß]', re.sub(r'%[-0-9.:]*[a-zA-Z]', '', s)) is not None


def norm(s):
    # wie Tr: fuehrende/folgende Leerzeichen und Doppelpunkt gehoeren nicht zum Schluessel
    return s.strip(' ').rstrip(' :') or s


def pascal_concat(expr):
    return ''.join(m[1:-1].replace("''", "'") for m in re.findall(LIT, expr))


keys = set()
# 1. Laufzeit
for f in glob.glob(os.path.join(ROOT, 'bin', '*', 'lang_fehlend_alle.txt')):
    for ln in open(f, encoding='utf-8-sig').read().split('\n'):
        ln = ln.rstrip('\r')
        if ln:
            keys.add(ln.replace('\\n', '\n'))
# 2. Quelltext
for f in glob.glob(os.path.join(ROOT, 'Source', '**', '*.pas'), recursive=True):
    src = open(f, encoding='utf-8-sig').read()
    for m in TR.finditer(src):
        keys.add(norm(pascal_concat(m.group(1))))
# 3. Tooltips (zweiter Text jedes Paares)
hints = open(os.path.join(ROOT, 'Source', 'UI', 'Granular.Hints.pas'), encoding='utf-8-sig').read()
for m in re.finditer(r"\(\s*(" + LIT + r")\s*,\s*(" + LIT + r")\s*\)", hints):
    keys.add(norm(pascal_concat(m.group(2))))
# 4. Reglertabelle der Hilfe (Kapitel 11 der fremdsprachigen Hilfe wird daraus erzeugt)
src = open(os.path.join(ROOT, 'Tools', 'Hilfe_Reglertabelle.py'), encoding='utf-8-sig').read()
ns = {'__file__': os.path.join(ROOT, 'Tools', 'Hilfe_Reglertabelle.py'), '__name__': 'lang_check'}
cwd = os.getcwd()
exec(src, ns)
os.chdir(cwd)
def _rec(t):
    keys.add(norm(t))
    return '' + t      # anders als die Eingabe: vst_tr soll alle Teile uebersetzen
ns['build_block'](_rec)
keys = {k for k in keys if k and has_letter(k)}


def esc(s):
    return s.replace('\r\n', '\n').replace('\n', '\\n')


if '--alle' in sys.argv:
    with open(os.path.join(LANG, '_alle_texte.txt'), 'w', encoding='utf-8') as f:
        for k in sorted(keys):
            f.write(esc(k) + '\t\n')
    print('%d Texte -> Sprachen/_alle_texte.txt' % len(keys))

bad = 0
for lf in sorted(glob.glob(os.path.join(LANG, '[!_]*.txt'))):
    code = os.path.splitext(os.path.basename(lf))[0]
    have = set()
    for ln in open(lf, encoding='utf-8-sig').read().split('\n'):
        ln = ln.rstrip('\r')
        if ln and not ln.startswith('#') and '\t' in ln:
            have.add(ln.split('\t', 1)[0].replace('\\n', '\n'))
    # umbrochene Fassungen (Tooltips per WrapText) zaehlen wie der Text ohne Umbrueche
    have_norm = {' '.join(h.split()) for h in have}
    miss = sorted(k for k in keys if k not in have and ' '.join(k.split()) not in have_norm)
    out = os.path.join(LANG, '_fehlend_%s.txt' % code)
    if miss:
        with open(out, 'w', encoding='utf-8') as f:
            for k in miss:
                f.write(esc(k) + '\t\n')
        print('%s: %d von %d Texten fehlen -> Sprachen/_fehlend_%s.txt' % (code, len(miss), len(keys), code))
        bad = 1
    else:
        if os.path.exists(out):
            os.remove(out)
        print('%s: alle %d Texte uebersetzt' % (code, len(keys)))

# --- uebersetzte Dokumente: deutsche Vorlage seit der Uebersetzung geaendert? ---
import hashlib
DOCS = [('LIESMICH.txt', 'README_%s.txt'), (os.path.join('Eigene Toene', 'LIESMICH.txt'), os.path.join('Eigene Toene', 'README_%s.txt')),
        (os.path.join('Presets', 'LERNPFAD.txt'), os.path.join('Presets', 'LEARNING_PATH_%s.txt')),
        (os.path.join('Hilfe', 'Hilfe.rtf'), os.path.join('Hilfe', 'Hilfe_%s.rtf'))]


def finger(path):
    t = open(os.path.join(ROOT, path), encoding='utf-8-sig', errors='replace').read().replace('\r\n', '\n')
    if path.endswith('.rtf'):
        k = t.find('fs26 11. ')            # Kapitel 11 wird erzeugt - nur die Kapitel davor zaehlen
        t = t[:k] if k > 0 else t
        t = re.sub(r"Version \d+\.\d+", '', t)
    return hashlib.md5(t.encode('utf-8')).hexdigest()


for lf in sorted(glob.glob(os.path.join(LANG, '[!_]*.txt'))):
    code = os.path.splitext(os.path.basename(lf))[0]
    sf = os.path.join(LANG, '_stand_%s.txt' % code)
    old = {}
    if os.path.exists(sf):
        for ln in open(sf, encoding='utf-8').read().split('\n'):
            if '\t' in ln:
                a, b = ln.split('\t', 1)
                old[a] = b
    new = {}
    for de, tr in DOCS:
        tgt = tr % code.upper() if ('README' in tr or 'LEARNING' in tr) else tr % code
        if not os.path.exists(os.path.join(ROOT, tgt)):
            print('%s: Uebersetzung fehlt: %s (Vorlage %s)' % (code, tgt, de))
            bad = 1
            continue
        new[de] = finger(de)
        if '--stand' not in sys.argv and old.get(de) != new[de]:
            print('%s: veraltet: %s - die Vorlage %s hat sich geaendert (danach: lang_check.py --stand)' % (code, tgt, de))
            bad = 1
    if '--stand' in sys.argv:
        with open(sf, 'w', encoding='utf-8') as f:
            for de in sorted(new):
                f.write(de + '\t' + new[de] + '\n')
        print('%s: Stand der Uebersetzungen gemerkt' % code)
sys.exit(bad)
