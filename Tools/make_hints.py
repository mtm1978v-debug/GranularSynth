"""Erzeugt Source/UI/Granular.Hints.pas: Tooltip-Texte fuer alle Regler und Knoepfe aus der
Reglertabelle der Hilfe (Tools/Hilfe_Reglertabelle.py) - so stehen in Hilfe und Oberflaeche
dieselben Erklaerungen.

Aufruf (aus beliebigem Ordner):   python Tools/make_hints.py
Danach neu bauen. Regler ohne Eintrag meldet das Skript (dann TABS/PNAMES in der Reglertabelle
ergaenzen).
"""
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
os.chdir(ROOT)

# Daten der Reglertabelle laden (nur der Datenteil, nicht das Schreiben der Hilfe)
src = open('Tools/Hilfe_Reglertabelle.py', encoding='utf-8-sig').read()
ns = {'__file__': os.path.abspath('Tools/Hilfe_Reglertabelle.py')}
exec(src[:src.index('\ndef vst(')], ns)
TABS, PNAMES = ns['TABS'], ns['PNAMES']

# Parameternamen in der Reihenfolge von PARAM_INFO
params = open('Source/Engine/Granular.Params.pas', encoding='utf-8-sig').read()
names = re.findall(r"\(Name: '([^']*)';", params)
name_set = set(names)


def expand(spec):
    """VST-Namen einer Tabellenzeile -> Liste echter Parameternamen"""
    result = []
    osz_also = 'Osz2, Osz3 entsprechend' in spec or 'Osz2-Filter, Osz3-Filter entsprechend' in spec
    spec = re.sub(r'\([^)]*\)', '', spec)
    prefix = ''
    family = None
    for tok in [t.strip() for t in spec.split(',') if t.strip()]:
        if '...' in tok:
            # "Verz. Note aus … Verz. Ausgang Takt": alle mit demselben Wortanfang
            head = tok.split()[0]
            result += [n for n in names if n.startswith(head)]
            continue
        m = re.match(r'([A-Za-z]+)(\d)\.\.[A-Za-z]+(\d)\s*(.*)', tok)
        if m:
            family = (m.group(1), int(m.group(2)), int(m.group(3)))
            tok = m.group(4)
        cands = []
        if family:
            cands = ['%s%d %s' % (family[0], k, tok) for k in range(family[1], family[2] + 1)]
        else:
            cands = [tok]
        for c in cands:
            if c in name_set:
                result.append(c)
            elif ('Osz ' + c) in name_set:
                result.append('Osz ' + c)
            elif family is None and c.startswith('Hall ') and c[5:] in name_set:
                result.append(c[5:])
    if osz_also:
        extra = []
        for n in result:
            for k in ('2', '3'):
                if ('Osz' + k + ' ' + n) in name_set:
                    extra.append('Osz' + k + ' ' + n)      # z.B. 'FM Attack' -> 'Osz2 FM Attack'
                for a, b in (('Osz ', 'Osz' + k + ' '), ('Osz-', 'Osz' + k + '-')):
                    if n.startswith(a) and (b + n[len(a):]) in name_set:
                        extra.append(b + n[len(a):])
        result += extra
    return result


def pas(t):
    return "'" + t.replace("'", "''") + "'"


param_hint = {}
caption_hint = {}
for tab, items in TABS:
    for cap, text in items:
        text = text[0].upper() + text[1:]
        caption_hint.setdefault(cap, text)
        if cap in PNAMES:
            for n in expand(PNAMES[cap]):
                param_hint.setdefault(n, cap + ': ' + text)

missing = [n for n in names if n not in param_hint and n not in ('Tempo',)]
lines = []
lines.append('﻿' + '{ GranularSynth - Granular + FM Synthese\n  Copyright (C) 2026 Matthias Haberecht\n\n  This program is free software: you can redistribute it and/or modify it under the terms of the\n  GNU General Public License as published by the Free Software Foundation, either version 3 of the\n  License, or (at your option) any later version. This program is distributed in the hope that it\n  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or\n  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }\n\n' + 'unit Granular.Hints;')   # mit GPL-Kopf wie alle Quelltexte
lines.append('')
lines.append('{ ERZEUGT von Tools/make_hints.py aus der Reglertabelle der Hilfe - nicht von Hand aendern.')
lines.append('  Tooltip-Texte je Regler (ueber den Parameternamen) und je Knopfbeschriftung. }')
lines.append('')
lines.append('interface')
lines.append('')
lines.append('{ Tooltip eines Reglers (Index wie in Granular.Params), '' = keiner }')
lines.append('function ParamHint(Index: Integer): string;')
lines.append('{ Tooltip zu einer Knopf-/Schalterbeschriftung, '' = keiner }')
lines.append('function CaptionHint(const Caption: string): string;')
lines.append('')
lines.append('implementation')
lines.append('')
lines.append('uses')
lines.append('  System.SysUtils, Granular.Params;')
lines.append('')
lines.append('const')
items = sorted(param_hint.items())
lines.append('  PARAM_HINTS: array[0..%d, 0..1] of string = (' % (len(items) - 1))
for i, (n, t) in enumerate(items):
    lines.append('    (%s, %s)%s' % (pas(n), pas(t), ',' if i < len(items) - 1 else ''))
lines.append('  );')
caps = sorted(caption_hint.items())
lines.append('  CAPTION_HINTS: array[0..%d, 0..1] of string = (' % (len(caps) - 1))
for i, (c, t) in enumerate(caps):
    lines.append('    (%s, %s)%s' % (pas(c), pas(t), ',' if i < len(caps) - 1 else ''))
lines.append('  );')
lines.append('''
var
  GHints: array of string;   // je Regler, beim ersten Aufruf aufgebaut

function ParamHint(Index: Integer): string;
var
  I, P: Integer;
  N: string;
begin
  if GHints = nil then
  begin
    SetLength(GHints, PARAM_COUNT);
    for P := 0 to PARAM_COUNT - 1 do
    begin
      N := GetParamInfo(P).Name;
      for I := 0 to High(PARAM_HINTS) do
        if PARAM_HINTS[I, 0] = N then
        begin
          GHints[P] := PARAM_HINTS[I, 1];
          Break;
        end;
      // Matrix-Zeilen: gemeinsamer Text
      if (GHints[P] = '') and (P >= MATRIX_BASE) then
        GHints[P] := CaptionHint('Modulationsmatrix');
    end;
  end;
  if (Index >= 0) and (Index < Length(GHints)) then
    Result := GHints[Index]
  else
    Result := '';
end;

function CaptionHint(const Caption: string): string;
var
  I: Integer;
  C: string;
begin
  C := Trim(StringReplace(Caption, '&', '', [rfReplaceAll]));
  for I := 0 to High(CAPTION_HINTS) do
    if SameText(CAPTION_HINTS[I, 0], C) then
      Exit(CAPTION_HINTS[I, 1]);
  Result := '';
end;

end.''')
open('Source/UI/Granular.Hints.pas', 'w', encoding='utf-8', newline='\r\n').write('\n'.join(lines) + '\n')
print('%d Regler mit Tooltip, %d Beschriftungen' % (len(param_hint), len(caption_hint)))
print('ohne Eintrag (%d):' % len(missing))
for n in missing:
    print('  ' + n)
