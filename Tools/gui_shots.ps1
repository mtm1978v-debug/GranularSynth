# GUI-Check + Doku-Bilder in einem Durchgang (Windows PowerShell 5).
# Aufruf:  powershell -ExecutionPolicy Bypass -File Tools\gui_shots.ps1 [-Doc] [-Check125]
#   -Doc       100 %-Bilder direkt als Doku-Bilder (docs\screenshots, docs\screenshots\en) speichern
#   -Check125  zusaetzlich alle Reiter bei 125 % (nur Pruefbilder unter bin\Win64\gui_check)
# Pruefbilder (Uebersicht je 8 Reiter) landen in bin\Win64\gui_check\m<Skalierung>_<n>.png.
# Umlaute nur als [char] - die Datei ist ASCII (PowerShell 5 liest Skripte ohne BOM als ANSI).
param([switch]$Doc, [switch]$Check125)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class GS { [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
 public delegate bool EnumProc(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
 [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 public struct RECT { public int L, T, R, B; } }
"@
$root = Split-Path $PSScriptRoot -Parent
$bin = "$root\bin\Win64"
$chk = "$bin\gui_check"
$de = "$root\docs\screenshots"
New-Item -ItemType Directory -Force $chk, "$de\en" | Out-Null
$ae = [char]0xE4; $oe = [char]0xF6
# aussagekraeftige Anzeigen: Grains, Filter mit Resonanz, EQ-Kurve, Kompressor, Saettigung
$env:GRANULAR_PARAMS = "Grains an=1;Spray=20;Filter an=1;Cutoff=1800;Resonanz=45;EQ an=1;EQ B${ae}sse=5;EQ H${oe}hen=4;Kompressor an=1;S${ae}ttigung=30"

function SetLang($l) { foreach ($p in 'Win64', 'Win32') { [IO.File]::WriteAllText("$root\bin\$p\Sprache.txt", $l, (New-Object Text.UTF8Encoding $true)) } }
function Shot([string]$Out, [string]$Title = '') {
  [GS]::SetCursorPos(0, 0) | Out-Null   # Maus weg: sonst wird ein Tooltip fotografiert
  $p = Start-Process "$bin\GranularHost.exe" -ArgumentList "-autoplay", "$bin\GranularSynth.dll" -PassThru
  Start-Sleep -Seconds 18
  $p.Refresh(); $h = $p.MainWindowHandle
  if ($Title -ne '') {
    $script:found = [IntPtr]::Zero
    $cb = [GS+EnumProc]{ param($w, $x)
      $pid2 = 0; [GS]::GetWindowThreadProcessId($w, [ref]$pid2) | Out-Null
      if ($pid2 -eq $p.Id) { $sb = New-Object Text.StringBuilder 256; [GS]::GetWindowText($w, $sb, 256) | Out-Null
        if ($sb.ToString().StartsWith($Title)) { $script:found = $w } }
      return $true }
    [GS]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    $h = $script:found
  }
  if ($h -ne [IntPtr]::Zero) {
    $r = New-Object GS+RECT; [GS]::GetWindowRect($h, [ref]$r) | Out-Null
    $bmp = New-Object Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc(); [GS]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
    $bmp.Save($Out); $g.Dispose(); $bmp.Dispose()
  } else { "Fenster nicht gefunden: $Out" }
  Stop-Process -Id $p.Id
}
function Montage([string[]]$Files, [string]$Out) {
  $w = 638; $h = 412
  $o = New-Object Drawing.Bitmap ($w * 4), ($h * 2)
  $g = [Drawing.Graphics]::FromImage($o); $g.InterpolationMode = 'HighQualityBicubic'; $g.Clear([Drawing.Color]::Black)
  for ($k = 0; $k -lt $Files.Count; $k++) {
    $im = [Drawing.Image]::FromFile($Files[$k]); $s = [Math]::Min($w / $im.Width, $h / $im.Height)
    $g.DrawImage($im, ($k % 4) * $w, [Math]::Floor($k / 4) * $h, [int]($im.Width * $s), [int]($im.Height * $s)); $im.Dispose()
  }
  $o.Save($Out); $g.Dispose(); $o.Dispose()
}

# Reiter (Osz 3 = gleich wie Osz 1/2, ausgelassen): Index, deutscher und englischer Doku-Name
$tabs = @(@(0,'schnell','quick'), @(1,'grain','grain'), @(2,'samples','samples'), @(3,'osz','osc'), @(4,'osz2','osc2'),
  @(6,'filter','filter'), @(7,'modulation','modulation'), @(8,'lfo','lfo'), @(9,'timing','timing'),
  @(10,'effekte','effects'), @(11,'echo_hall','echo_reverb'), @(12,'summe','master'), @(13,'extras','extras'),
  @(14,'mischpult','mixer'), @(15,'leistung','performance'))
$scales = @(100); if ($Check125) { $scales += 125 }
foreach ($sc in $scales) {
  [IO.File]::WriteAllText("$bin\Fenstergroesse.txt", "$sc")
  foreach ($lang in 'de', 'en') {
    if ($lang -eq 'en' -and -not $Doc) { continue }   # Pruefung reicht auf Deutsch
    if ($lang -eq 'en' -and $sc -ne 100) { continue }
    SetLang $lang
    if ($lang -eq 'en') { $env:GRANULAR_LANGTEST = 'en' } else { $env:GRANULAR_LANGTEST = '' }
    $files = @()
    foreach ($t in $tabs) {
      $env:GRANULAR_TAB = "$($t[0])"
      if ($Doc -and $sc -eq 100 -and $t[1] -ne 'osz2') {
        if ($lang -eq 'de') { $f = "$de\$($t[1]).png" } else { $f = "$de\en\$($t[2]).png" }
      } else { $f = "$chk\s${sc}_${lang}_$($t[0]).png" }
      Shot $f; $files += $f
    }
    $env:GRANULAR_TAB = ''
    Montage $files[0..7] "$chk\m${sc}_${lang}_0.png"
    Montage $files[8..($files.Count - 1)] "$chk\m${sc}_${lang}_1.png"
  }
}
if ($Doc) {
  # Sonderfenster (nur deutsch) und englische Summe fuer die deutsche README
  SetLang 'de'; $env:GRANULAR_LANGTEST = ''; [IO.File]::WriteAllText("$bin\Fenstergroesse.txt", "100")
  $env:GRANULAR_FREELFO = '1'; Shot "$de\lfo_frei.png" 'LFO 1 - freie Form'; $env:GRANULAR_FREELFO = ''
  $env:GRANULAR_WAVEEDIT = '1'; Shot "$de\osz_welle.png" 'Osz 1 - Welle zeichnen'; $env:GRANULAR_WAVEEDIT = ''
  $env:GRANULAR_AUDIOEDIT = '1'; Shot "$de\audio_bearbeiten.png" 'Sample-Editor'; $env:GRANULAR_AUDIOEDIT = ''
  Copy-Item "$de\en\master.png" "$de\summe_en.png"
}
$env:GRANULAR_PARAMS = ''; $env:GRANULAR_LANGTEST = ''
SetLang 'de'; [IO.File]::WriteAllText("$bin\Fenstergroesse.txt", "100")
"fertig: Pruefbilder in $chk"
