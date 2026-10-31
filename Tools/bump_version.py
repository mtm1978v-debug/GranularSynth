"""Version vor jedem Deploy um eins nach dem Punkt erhoehen (1.0 -> 1.1 -> ... -> 1.10 ...).
Aufruf: python Tools/bump_version.py          (Nebenversion +1)
        python Tools/bump_version.py --major  (Hauptversion +1, Nebenversion 0 - z.B. VST3 = 2.0)
        python Tools/bump_version.py --rc     (nur Version.rc aus der aktuellen Version neu schreiben)
Aendert APP_VERSION_MAJOR/MINOR/APP_VERSION in Source/Engine/Granular.Params.pas, die Version im Untertitel
von Hilfe/Hilfe.rtf, schreibt Version.rc
(Windows-Versionsinfo fuer DLL und Host, im Explorer unter Eigenschaften > Details) und gibt die Version aus."""
import os, re, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
p = os.path.join(root, 'Source', 'Engine', 'Granular.Params.pas')
s = open(p, encoding='utf-8-sig').read()
ma = int(re.search(r'APP_VERSION_MAJOR = (\d+);', s).group(1))
mi = int(re.search(r'APP_VERSION_MINOR = (\d+);', s).group(1))
if '--major' in sys.argv:
    ma, mi = ma + 1, 0
elif '--rc' not in sys.argv:
    mi += 1
s = re.sub(r'APP_VERSION_MAJOR = \d+;', 'APP_VERSION_MAJOR = %d;' % ma, s)
s = re.sub(r'APP_VERSION_MINOR = \d+;', 'APP_VERSION_MINOR = %d;' % mi, s)
s = re.sub(r"APP_VERSION = '[^']*';", "APP_VERSION = '%d.%d';" % (ma, mi), s)
open(p, 'w', encoding='utf-8-sig', newline='').write(s)   # mit BOM: Delphi liest Dateien ohne BOM als ANSI (Umlaute!)

Z = '\\0'   # Nullterminator im RC-Text
rc = '\r\n'.join([
    '// automatisch erzeugt von Tools/bump_version.py - nicht von Hand aendern',
    '1 VERSIONINFO',
    'FILEVERSION %d,%d,0,0' % (ma, mi),
    'PRODUCTVERSION %d,%d,0,0' % (ma, mi),
    'FILEOS 0x40004',
    'FILETYPE 0x2',
    '{',
    '  BLOCK "StringFileInfo"',
    '  {',
    '    BLOCK "040704E4"',
    '    {',
    '      VALUE "CompanyName", "HABI M%s"' % Z,
    '      VALUE "FileDescription", "GranularSynth - Granular + FM Synthese%s"' % Z,
    '      VALUE "FileVersion", "%d.%d%s"' % (ma, mi, Z),
    '      VALUE "ProductName", "GranularSynth%s"' % Z,
    '      VALUE "ProductVersion", "%d.%d%s"' % (ma, mi, Z),
    '      VALUE "LegalCopyright", "(C) 2026 Matthias Haberecht, GNU GPL v3+%s"' % Z,
    '    }',
    '  }',
    '  BLOCK "VarFileInfo"',
    '  {',
    '    VALUE "Translation", 0x0407, 1252',
    '  }',
    '}',
    ''])
open(os.path.join(root, 'Version.rc'), 'w', encoding='cp1252', newline='').write(rc)
# Untertitel der Hilfe: "FM . Synthese . HABI M . Version x.y"
hp = os.path.join(root, 'Hilfe', 'Hilfe.rtf')
h = open(hp, encoding='latin-1').read()
h = re.sub(r"(HABI M \\'b7 Version )\d+\.\d+", lambda m: m.group(1) + '%d.%d' % (ma, mi), h)
open(hp, 'w', encoding='latin-1', newline='').write(h)
print('%d.%d' % (ma, mi))
