"""Zugriffe und Anfragen auf GitHub (github.com/mtm1978v-debug/GranularSynth) abfragen.
Aufruf: python Tools/github_stats.py
Braucht die angemeldete GitHub CLI (gh). GitHub haelt Aufrufe/Klone nur 14 Tage vor - das Skript
schreibt sie deshalb tageweise in eine Verlaufsdatei ausserhalb des Projektarchivs
(..\\GranularSynth-Release\\statistik.csv) und zeigt die Summen seit Beginn."""
import csv, json, os, subprocess, sys

REPO = 'mtm1978v-debug/GranularSynth'
GH = r'C:\Program Files\GitHub CLI\gh.exe'
HIST = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'GranularSynth-Release', 'statistik.csv')


def api(path):
    out = subprocess.run([GH, 'api', path], capture_output=True, text=True, encoding='utf-8')
    if out.returncode != 0:
        sys.exit('gh-Fehler bei %s: %s' % (path, out.stderr.strip()))
    return json.loads(out.stdout)


views = api('repos/%s/traffic/views' % REPO)['views']
clones = api('repos/%s/traffic/clones' % REPO)['clones']
refs = api('repos/%s/traffic/popular/referrers' % REPO)
info = api('repos/%s' % REPO)
rels = api('repos/%s/releases' % REPO)
issues = api('repos/%s/issues?state=open&per_page=50' % REPO)

# Verlauf: Tag -> [Aufrufe, Besucher, Klone, Kloner]; neuere Abfragen ueberschreiben denselben Tag
hist = {}
if os.path.exists(HIST):
    with open(HIST, newline='', encoding='utf-8') as f:
        for r in csv.reader(f):
            if r and r[0] != 'Tag':
                hist[r[0]] = [int(x) for x in r[1:5]]
for v in views:
    hist.setdefault(v['timestamp'][:10], [0, 0, 0, 0])[0:2] = [v['count'], v['uniques']]
for c in clones:
    hist.setdefault(c['timestamp'][:10], [0, 0, 0, 0])[2:4] = [c['count'], c['uniques']]
os.makedirs(os.path.dirname(HIST), exist_ok=True)
with open(HIST, 'w', newline='', encoding='utf-8') as f:
    w = csv.writer(f)
    w.writerow(['Tag', 'Aufrufe', 'Besucher', 'Klone', 'Kloner'])
    for d in sorted(hist):
        w.writerow([d] + hist[d])

tot = [sum(x[i] for x in hist.values()) for i in range(4)]
print('GranularSynth auf GitHub')
print('  Sterne %d, Beobachter %d, Forks %d' % (info['stargazers_count'], info['subscribers_count'], info['forks_count']))
print('  Seitenaufrufe seit Beginn: %d (Tagesbesucher summiert %d), Klone: %d' % (tot[0], tot[1], tot[2]))
last = [d for d in sorted(hist) if hist[d][0] or hist[d][2]][-5:]
for d in last:
    print('    %s: %d Aufrufe, %d Besucher, %d Klone' % (d, *hist[d][:3]))
for r in rels:
    print('  Downloads %s: %s' % (r['tag_name'], ', '.join('%s %d' % (a['name'], a['download_count']) for a in r['assets'])))
if refs:
    print('  Herkunft: ' + ', '.join('%s (%d)' % (r['referrer'], r['count']) for r in refs))
real = [i for i in issues if 'pull_request' not in i]
prs = [i for i in issues if 'pull_request' in i]
print('  Offene Issues: %d, offene Pull Requests: %d' % (len(real), len(prs)))
for i in real + prs:
    print('    #%d %s  [%s] von %s' % (i['number'], i['title'], ', '.join(l['name'] for l in i['labels']), i['user']['login']))
