<#
  GranularSynth - Installation
  ----------------------------
  Liegt in der Auslieferung neben den Ordnern Win32\ und Win64\ (deploy.bat kopiert es dorthin) und wird
  von Setup.exe (Administratorrechte per Manifest) gestartet. Fenster: Plattform (64/32 Bit), was installiert werden soll
  (VST2 normal + FX, VST3, Test-Host) und die Zielordner (aus der Registry bzw. Windows-Standard).
  Je Format entsteht ein Ordner "GranularSynth" mit dem Plugin und seinen Daten (Presets, Beispieltoene,
  Hilfe, Eigene Toene) - das Plugin sucht sie in seinem eigenen Ordner.
  Eigene Presets und eigene Toene werden nie geloescht oder ueberschrieben.

  Windows-Programmliste: je Plattform ein Eintrag "GranularSynth (64 Bit)" bzw. "(32 Bit)" mit
  Deinstallieren und Aendern. Setup.exe + Install.ps1 liegen dafuer in "Programme\GranularSynth Setup".
  Der Eintrag merkt sich die Auswahl (VST2/VST3/Host, Ordner): ein neues Setup schlaegt sie wieder vor
  (Update). In jedem Zielordner listet "Setup-Dateien.txt" die mitgelieferten Dateien - nur die
  entfernt die Deinstallation; eigene Presets und Toene bleiben auf Wunsch erhalten.

  Aufruf ohne Fenster (Test / Skript):
    Install.ps1 -Auto -Platform Win64 -Vst2 -Vst3 [-Host] [-Vst2Dir <Pfad>] [-Vst3Dir <Pfad>]
    Install.ps1 -Uninstall -Platform Win64 [-Auto [-RemoveUserData]]
    Install.ps1 -CheckOnline                  (neueste Version auf GitHub anzeigen, nichts aendern)
    Install.ps1 -OnlineUpdate -Auto           (neueste Version laden und die installierten Plattformen aktualisieren)

  Online-Update: fragt https://api.github.com/repos/mtm1978v-debug/GranularSynth/releases/latest ab, laedt das
  Release-ZIP in den Temp-Ordner, prueft die SHA-256-Pruefsumme, die GitHub zum ZIP angibt, entpackt es und
  startet dessen Install.ps1 mit der gemerkten Auswahl je installierter Plattform (Programmliste).
#>
param(
  [switch]$Auto,
  [ValidateSet('Win32', 'Win64')][string]$Platform = '',
  [switch]$Vst2,
  [switch]$Vst3,
  [switch]$TestHost,
  [string]$Vst2Dir = '',
  [string]$Vst3Dir = '',
  [switch]$Preview,         # nur das Fenster zeigen (ohne Administratorrechte, zum Ansehen)
  [switch]$Uninstall,       # aus der Windows-Programmliste: diese Plattform entfernen
  [switch]$RemoveUserData,  # mit -Uninstall -Auto: auch eigene Presets/Toene loeschen
  [switch]$FromTemp,        # intern: Deinstallation laeuft aus einer Kopie im Temp-Ordner
  [switch]$NoRegister,      # Test: nichts in die Programmliste eintragen
  [switch]$CheckOnline,     # nur nachsehen, ob es auf GitHub eine neuere Version gibt
  [switch]$OnlineUpdate,    # neueste Version von GitHub laden und installieren
  [string]$DownloadOnly = '', # Test: ZIP laden, pruefen und hierhin entpacken, nichts installieren
  [switch]$StartUpdate      # vom Plugin aus gestartet: Fenster oeffnen und gleich das Online-Update anbieten
)

$ErrorActionPreference = 'Stop'
$Src = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# VST2-Ordner: Registry (64 Bit: HKLM\SOFTWARE\VST, 32 Bit: WOW6432Node), sonst Standard
function Get-Vst2Default([string]$Plat) {
  $keys = if ($Plat -eq 'Win64') { @('HKLM:\SOFTWARE\VST') } else { @('HKLM:\SOFTWARE\WOW6432Node\VST', 'HKLM:\SOFTWARE\VST') }
  foreach ($k in $keys) {
    try {
      $p = (Get-ItemProperty -Path $k -Name 'VSTPluginsPath' -ErrorAction Stop).VSTPluginsPath
      if ($p) { return $p.TrimEnd('\') }
    } catch { }
  }
  if ($Plat -eq 'Win64') { return Join-Path $env:ProgramFiles 'VSTPlugins' }
  if (${env:ProgramFiles(x86)}) { return Join-Path ${env:ProgramFiles(x86)} 'VSTPlugins' }
  return Join-Path $env:ProgramFiles 'VSTPlugins'
}

# VST3-Ordner: fest von Steinberg vorgegeben (Common Files\VST3 der jeweiligen Bitbreite)
function Get-Vst3Default([string]$Plat) {
  if ($Plat -eq 'Win32' -and ${env:CommonProgramFiles(x86)}) { return Join-Path ${env:CommonProgramFiles(x86)} 'VST3' }
  return Join-Path $env:CommonProgramFiles 'VST3'
}

# Daten neben das Plugin: Programm-Dateien ueberschreiben, Nutzerdaten nie loeschen
function Copy-Data([string]$From, [string]$To, [System.Collections.Generic.List[string]]$Log) {
  foreach ($d in @('Presets', 'Beispieltoene', 'Hilfe', 'Sprachen')) {
    $s = Join-Path $From $d
    if (Test-Path $s) {
      $t = Join-Path $To $d
      New-Item -ItemType Directory -Force -Path $t | Out-Null
      Copy-Item -Path (Join-Path $s '*') -Destination $t -Force -Recurse
      $Log.Add("  $d\")
    }
  }
  $own = Join-Path $To 'Eigene Toene'
  New-Item -ItemType Directory -Force -Path $own | Out-Null
  foreach ($r in @('Eigene Toene\LIESMICH.txt', 'Eigene Toene\README_EN.txt')) {
    $readme = Join-Path $From $r
    if (Test-Path $readme) { Copy-Item $readme $own -Force }
  }
  foreach ($f in @('LIESMICH.txt', 'README_EN.txt', 'CHANGELOG.md', 'LICENSE.txt')) {
    $s = Join-Path $From $f
    if (Test-Path $s) { Copy-Item $s $To -Force }
  }
}

# ---------- Online-Update (GitHub-Releases) ----------
$RepoApi = 'https://api.github.com/repos/mtm1978v-debug/GranularSynth/releases/latest'

function Get-LatestRelease {
  # Windows PowerShell 5.1: TLS 1.2 fuer GitHub einschalten
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $r = Invoke-RestMethod -Uri $RepoApi -Headers @{ 'User-Agent' = 'GranularSynth-Setup' } -TimeoutSec 15
  $zip = $r.assets | Where-Object { $_.name -like 'GranularSynth-*.zip' } | Select-Object -First 1
  if (-not $zip) { throw 'Im neuesten Release ist kein GranularSynth-ZIP.' }
  $digest = ''
  if ($zip.PSObject.Properties.Name -contains 'digest' -and $zip.digest -like 'sha256:*') { $digest = $zip.digest.Substring(7) }
  [pscustomobject]@{ Version = $r.tag_name.TrimStart('v'); Url = $zip.browser_download_url; Size = $zip.size
                     Sha256 = $digest; Notes = $r.body; Page = $r.html_url }
}

function Test-Newer([string]$Online, [string]$Local) {
  if (-not $Local) { return $true }
  try { return ([version]$Online) -gt ([version]$Local) } catch { return $Online -ne $Local }
}

# installierte Version: die hoechste der Programmlisten-Eintraege
function Get-InstalledVersion {
  $v = ''
  foreach ($p in @('Win64', 'Win32')) {
    $e = Get-Installed $p
    if ($e -and $e.DisplayVersion -and (Test-Newer $e.DisplayVersion $v)) { $v = $e.DisplayVersion }
  }
  return $v
}

# ZIP laden, Pruefsumme kontrollieren, entpacken; liefert den Ordner mit Install.ps1
function Get-ReleaseFiles($Rel, [string]$Target) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  if (Test-Path $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $Target | Out-Null
  $zipPath = Join-Path $Target 'GranularSynth.zip'
  $ProgressPreference = 'SilentlyContinue'      # Fortschrittsbalken bremst den Download stark
  Invoke-WebRequest -Uri $Rel.Url -OutFile $zipPath -Headers @{ 'User-Agent' = 'GranularSynth-Setup' } -UseBasicParsing
  if ($Rel.Size -and (Get-Item $zipPath).Length -ne $Rel.Size) { throw 'Download unvollstaendig (Groesse stimmt nicht).' }
  if ($Rel.Sha256) {
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash
    if ($h -ne $Rel.Sha256.ToUpper()) { throw 'Pruefsumme des Downloads stimmt nicht - Update abgebrochen.' }
  }
  Expand-Archive -LiteralPath $zipPath -DestinationPath $Target -Force
  $inst = Get-ChildItem -LiteralPath $Target -Recurse -Filter 'Install.ps1' | Select-Object -First 1
  if (-not $inst) { throw 'Im Download fehlt Install.ps1.' }
  return $inst.DirectoryName
}

# neue Version mit der gemerkten Auswahl je installierter Plattform installieren (Skript der neuen Version)
function Invoke-OnlineUpdate($Rel) {
  $dir = Get-ReleaseFiles $Rel (Join-Path $env:TEMP 'GranularSynth-Update')
  $script = Join-Path $dir 'Install.ps1'
  $log = New-Object System.Collections.Generic.List[string]
  $any = $false
  foreach ($p in @('Win64', 'Win32')) {
    $e = Get-Installed $p
    if (-not $e) { continue }
    $any = $true
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Auto', '-Platform', $p)
    if ($e.Vst2 -eq 1) { $a += @('-Vst2', '-Vst2Dir', $e.Vst2Dir) }
    if ($e.Vst3 -eq 1) { $a += @('-Vst3', '-Vst3Dir', $e.Vst3Dir) }
    if ($e.TestHost -eq 1) { $a += '-TestHost' }
    $out = & powershell.exe @a 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Installation ($p) fehlgeschlagen: $out" }
    $log.Add("$p aktualisiert")
  }
  if (-not $any) { throw 'Es ist noch keine Installation eingetragen - bitte einmal normal installieren.' }
  return $log
}

# ---------- Programmliste (Uninstall-Eintrag) ----------
$UninstRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$SetupHome = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) 'GranularSynth Setup'
function Get-RegKey([string]$Plat) { Join-Path $UninstRoot "GranularSynth_$Plat" }

function Get-Installed([string]$Plat) {
  $k = Get-RegKey $Plat
  if (-not (Test-Path $k)) { return $null }
  return Get-ItemProperty -Path $k
}

# Version aus CHANGELOG.md (erste "## Version x.y")
function Get-ShippedVersion {
  foreach ($c in @((Join-Path $Src 'Win64\CHANGELOG.md'), (Join-Path $Src 'Win32\CHANGELOG.md'), (Join-Path $Src 'CHANGELOG.md'))) {
    if (Test-Path $c) {
      $m = Select-String -Path $c -Pattern '^## Version (\d+\.\d+)' | Select-Object -First 1
      if ($m) { return $m.Matches[0].Groups[1].Value }
    }
  }
  return ''
}

function Register-Granular([string]$Plat, [bool]$DoVst2, [bool]$DoVst3, [bool]$DoHost, [string]$Dir2, [string]$Dir3) {
  # Setup + Skript an einen festen Ort: von dort startet Windows "Deinstallieren" / "Aendern"
  New-Item -ItemType Directory -Force -Path $SetupHome | Out-Null
  Copy-Item (Join-Path $Src 'Install.ps1') $SetupHome -Force
  if (Test-Path (Join-Path $Src 'Setup.exe')) { Copy-Item (Join-Path $Src 'Setup.exe') $SetupHome -Force }
  $exe = Join-Path $SetupHome 'Setup.exe'
  $k = Get-RegKey $Plat
  New-Item -Path $k -Force | Out-Null
  $bits = if ($Plat -eq 'Win64') { '64 Bit' } else { '32 Bit' }
  $size = 0
  foreach ($d in @($(if ($DoVst2) { Join-Path $Dir2 'GranularSynth' }), $(if ($DoVst3) { Join-Path $Dir3 'GranularSynth' }))) {
    if ($d -and (Test-Path $d)) { $size += (Get-ChildItem $d -Recurse -File | Measure-Object Length -Sum).Sum }
  }
  $v = @{
    DisplayName = "GranularSynth ($bits)"; DisplayVersion = (Get-ShippedVersion); Publisher = 'Matthias Haberecht'
    InstallLocation = $(if ($DoVst2) { Join-Path $Dir2 'GranularSynth' } else { Join-Path $Dir3 'GranularSynth' })
    UninstallString = "`"$exe`" -Uninstall -Platform $Plat"
    ModifyPath = "`"$exe`""
    Comments = 'Granular + FM Synthese (VST2/VST3), GNU GPL v3+'
    Vst2 = [int]$DoVst2; Vst3 = [int]$DoVst3; TestHost = [int]$DoHost; Vst2Dir = $Dir2; Vst3Dir = $Dir3
  }
  foreach ($n in $v.Keys) { Set-ItemProperty -Path $k -Name $n -Value $v[$n] }
  Set-ItemProperty -Path $k -Name 'EstimatedSize' -Value ([int]($size / 1024)) -Type DWord
  Set-ItemProperty -Path $k -Name 'NoRepair' -Value 1 -Type DWord
  if (Test-Path (Join-Path $Dir2 'GranularSynth\GranularSynth.dll')) {
    Set-ItemProperty -Path $k -Name 'DisplayIcon' -Value (Join-Path $Dir2 'GranularSynth\GranularSynth.dll')
  }
}

# Zielordner "GranularSynth" leeren: nur mitgelieferte Dateien (Setup-Dateien.txt), eigene Daten auf Wunsch behalten
function Remove-Target([string]$Dir, [bool]$KeepUser, [System.Collections.Generic.List[string]]$Log) {
  if (-not $Dir -or -not (Test-Path $Dir)) { return }
  if (-not $KeepUser) {
    Remove-Item -LiteralPath $Dir -Recurse -Force
    $Log.Add("  $Dir entfernt")
    return
  }
  $list = Join-Path $Dir 'Setup-Dateien.txt'
  if (Test-Path $list) {
    foreach ($rel in (Get-Content -LiteralPath $list -Encoding UTF8)) {
      if ($rel) {
        $f = Join-Path $Dir $rel
        if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force }
      }
    }
    Remove-Item -LiteralPath $list -Force
  }
  # leere Ordner von unten nach oben weg
  Get-ChildItem -LiteralPath $Dir -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
    Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } | Remove-Item -Force
  if (-not (Get-ChildItem -LiteralPath $Dir -Force)) { Remove-Item -LiteralPath $Dir -Force; $Log.Add("  $Dir entfernt") }
  else { $Log.Add("  $Dir : eigene Presets/Toene behalten") }
}

function Uninstall-Granular([string]$Plat, [bool]$KeepUser) {
  $log = New-Object System.Collections.Generic.List[string]
  $e = Get-Installed $Plat
  if ($e) {
    if ($e.Vst2 -eq 1) { Remove-Target (Join-Path $e.Vst2Dir 'GranularSynth') $KeepUser $log }
    if ($e.Vst3 -eq 1) { Remove-Target (Join-Path $e.Vst3Dir 'GranularSynth') $KeepUser $log }
    Remove-Item -Path (Get-RegKey $Plat) -Recurse -Force
  }
  # keine Plattform mehr eingetragen -> Setup-Kopie weg (laeuft ggf. noch kurz: einige Male versuchen)
  if (-not (Get-Installed 'Win32') -and -not (Get-Installed 'Win64') -and (Test-Path $SetupHome)) {
    for ($i = 0; $i -lt 20 -and (Test-Path $SetupHome); $i++) {
      try { Remove-Item -LiteralPath $SetupHome -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 500 }
    }
  }
  return $log
}

# Setup-Dateien.txt: alle Dateien, die das Setup in den Zielordner gelegt hat (relativ); bestehende Liste ergaenzen
function Write-FileList([string]$From, [string]$To, [string[]]$Extra) {
  $rel = New-Object System.Collections.Generic.List[string]
  foreach ($d in @('Presets', 'Beispieltoene', 'Hilfe', 'Sprachen')) {
    $s = Join-Path $From $d
    if (Test-Path $s) {
      Get-ChildItem -LiteralPath $s -Recurse -File | ForEach-Object { $rel.Add($d + $_.FullName.Substring($s.Length)) }
    }
  }
  foreach ($f in @('Eigene Toene\LIESMICH.txt', 'Eigene Toene\README_EN.txt', 'LIESMICH.txt', 'README_EN.txt', 'CHANGELOG.md', 'LICENSE.txt') + $Extra) { $rel.Add($f) }
  $list = Join-Path $To 'Setup-Dateien.txt'
  if (Test-Path $list) { foreach ($l in (Get-Content -LiteralPath $list -Encoding UTF8)) { if ($l) { $rel.Add($l) } } }
  $rel | Sort-Object -Unique | Set-Content -LiteralPath $list -Encoding UTF8
}

function Install-Granular([string]$Plat, [bool]$DoVst2, [bool]$DoVst3, [bool]$DoHost, [string]$Dir2, [string]$Dir3) {
  $from = Join-Path $Src $Plat
  if (-not (Test-Path (Join-Path $from 'GranularSynth.dll'))) { throw "Auslieferung fuer $Plat nicht gefunden: $from" }
  $log = New-Object System.Collections.Generic.List[string]
  if ($DoVst2) {
    $t = Join-Path $Dir2 'GranularSynth'
    New-Item -ItemType Directory -Force -Path $t | Out-Null
    Copy-Item (Join-Path $from 'GranularSynth.dll') $t -Force
    Copy-Item (Join-Path $from 'GranularSynth FX.dll') $t -Force
    $log.Add("VST2 nach $t :")
    $log.Add('  GranularSynth.dll, GranularSynth FX.dll')
    if ($DoHost) {
      Copy-Item (Join-Path $from 'GranularHost.exe') $t -Force
      $log.Add('  GranularHost.exe (Test-Host)')
    }
    Copy-Data $from $t $log
    Write-FileList $from $t @('GranularSynth.dll', 'GranularSynth FX.dll', 'GranularHost.exe')
  }
  if ($DoVst3) {
    $t = Join-Path $Dir3 'GranularSynth'
    New-Item -ItemType Directory -Force -Path $t | Out-Null
    Copy-Item (Join-Path $from 'GranularSynth.vst3') $t -Force
    $log.Add("VST3 nach $t :")
    $log.Add('  GranularSynth.vst3 (Instrument und FX)')
    if ($DoHost -and -not $DoVst2) {
      Copy-Item (Join-Path $from 'GranularHost.exe') $t -Force
      Copy-Item (Join-Path $from 'GranularSynth.dll') $t -Force    # der Test-Host laedt die VST2-DLL
      $log.Add('  GranularHost.exe + GranularSynth.dll (Test-Host)')
    }
    Copy-Data $from $t $log
    Write-FileList $from $t @('GranularSynth.vst3', 'GranularHost.exe', 'GranularSynth.dll')
  }
  if (-not $NoRegister) { Register-Granular $Plat $DoVst2 $DoVst3 $DoHost $Dir2 $Dir3 }
  return $log
}

# ---------- Deinstallieren (Windows: Einstellungen > Apps) ----------
if ($Uninstall) {
  if (-not $Platform) { $Platform = 'Win64' }
  # aus einer Kopie im Temp-Ordner laufen: die Setup-Kopie im Programme-Ordner wird mit geloescht
  if (-not $FromTemp -and -not $Auto -and $Src.TrimEnd('\') -ieq $SetupHome.TrimEnd('\')) {
    $tmp = Join-Path $env:TEMP 'GranularSynth-Uninstall.ps1'
    Copy-Item $MyInvocation.MyCommand.Path $tmp -Force
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"", '-Uninstall', '-FromTemp', '-Platform', $Platform)
    exit 0
  }
  if ($Auto) {
    Uninstall-Granular $Platform (-not $RemoveUserData.IsPresent) | ForEach-Object { Write-Output $_ }
    exit 0
  }
  Add-Type -AssemblyName System.Windows.Forms
  $bits = if ($Platform -eq 'Win64') { '64 Bit' } else { '32 Bit' }
  $a = [System.Windows.Forms.MessageBox]::Show(
    "GranularSynth ($bits) wird entfernt.`r`n`r`nEigene Presets und eigene Toene behalten?`r`n" +
    "  Ja = behalten (nur die mitgelieferten Dateien werden entfernt)`r`n  Nein = alles loeschen",
    'GranularSynth deinstallieren', 'YesNoCancel', 'Question')
  if ($a -eq 'Cancel') { exit 1 }
  try {
    $log = Uninstall-Granular $Platform ($a -eq 'Yes')
    [System.Windows.Forms.MessageBox]::Show("GranularSynth ($bits) wurde entfernt.`r`n`r`n" + ($log -join "`r`n"), 'GranularSynth') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show("Fehler: $($_.Exception.Message)", 'GranularSynth', 'OK', 'Error') | Out-Null
  }
  exit 0
}

# ---------- Online ohne Fenster ----------
if ($CheckOnline -or $DownloadOnly) {
  $rel = Get-LatestRelease
  "Neueste Version auf GitHub: $($rel.Version)  ($([math]::Round($rel.Size / 1MB)) MB, Pruefsumme: $(if ($rel.Sha256) { 'ja' } else { 'nein' }))"
  "Installiert: $(Get-InstalledVersion)"
  if ($DownloadOnly) { "Entpackt nach: $(Get-ReleaseFiles $rel $DownloadOnly)" }
  exit 0
}
if ($OnlineUpdate -and $Auto) {
  Invoke-OnlineUpdate (Get-LatestRelease) | ForEach-Object { Write-Output $_ }
  exit 0
}

# ---------- ohne Fenster ----------
if ($Auto) {
  if (-not $Platform) { $Platform = if ([Environment]::Is64BitOperatingSystem) { 'Win64' } else { 'Win32' } }
  if (-not $Vst2Dir) { $Vst2Dir = Get-Vst2Default $Platform }
  if (-not $Vst3Dir) { $Vst3Dir = Get-Vst3Default $Platform }
  $r = Install-Granular $Platform $Vst2.IsPresent $Vst3.IsPresent $TestHost.IsPresent $Vst2Dir $Vst3Dir
  $r | ForEach-Object { Write-Output $_ }
  exit 0
}

# ---------- Fenster ----------
if (-not $Preview -and -not (Test-Admin)) {
  # Programme-Ordner brauchen Administratorrechte: Windows fragt (UAC)
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
  if ($StartUpdate) { $a += '-StartUpdate' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList $a
  exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$f = New-Object System.Windows.Forms.Form
$f.Text = 'GranularSynth installieren'
$f.ClientSize = New-Object System.Drawing.Size(640, 400)
$f.StartPosition = 'CenterScreen'
$f.FormBorderStyle = 'FixedDialog'
$f.MaximizeBox = $false
$f.Font = New-Object System.Drawing.Font('Segoe UI', 10)

function Add-Label($text, $x, $y, $w = 600) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 22)
  $f.Controls.Add($l); $l
}

Add-Label 'Plattform (muss zur DAW passen - altes FL Studio 11 meist 32 Bit):' 16 14 | Out-Null
$r64 = New-Object System.Windows.Forms.RadioButton
$r64.Text = '64 Bit'; $r64.Location = New-Object System.Drawing.Point(24, 40); $r64.AutoSize = $true
$r32 = New-Object System.Windows.Forms.RadioButton
$r32.Text = '32 Bit'; $r32.Location = New-Object System.Drawing.Point(120, 40); $r32.AutoSize = $true
$r64.Checked = [Environment]::Is64BitOperatingSystem
if ($r64.Checked -and -not (Get-Installed 'Win64') -and (Get-Installed 'Win32')) { $r64.Checked = $false }
$r32.Checked = -not $r64.Checked
$f.Controls.AddRange(@($r64, $r32))

$c2 = New-Object System.Windows.Forms.CheckBox
$c2.Text = 'VST2 (GranularSynth + GranularSynth FX)'; $c2.Location = New-Object System.Drawing.Point(16, 80); $c2.AutoSize = $true; $c2.Checked = $true
$t2 = New-Object System.Windows.Forms.TextBox
$t2.Location = New-Object System.Drawing.Point(36, 108); $t2.Size = New-Object System.Drawing.Size(500, 26)
$b2 = New-Object System.Windows.Forms.Button
$b2.Text = 'Ordner...'; $b2.Location = New-Object System.Drawing.Point(544, 106); $b2.Size = New-Object System.Drawing.Size(80, 28)

$c3 = New-Object System.Windows.Forms.CheckBox
$c3.Text = 'VST3 (GranularSynth.vst3 mit Instrument und FX)'; $c3.Location = New-Object System.Drawing.Point(16, 146); $c3.AutoSize = $true; $c3.Checked = $true
$t3 = New-Object System.Windows.Forms.TextBox
$t3.Location = New-Object System.Drawing.Point(36, 174); $t3.Size = New-Object System.Drawing.Size(500, 26)
$b3 = New-Object System.Windows.Forms.Button
$b3.Text = 'Ordner...'; $b3.Location = New-Object System.Drawing.Point(544, 172); $b3.Size = New-Object System.Drawing.Size(80, 28)

$ch = New-Object System.Windows.Forms.CheckBox
$ch.Text = 'Test-Host (GranularHost.exe) dazu'; $ch.Location = New-Object System.Drawing.Point(16, 212); $ch.AutoSize = $true

$HintNew = 'In jeden Zielordner kommt ein Ordner "GranularSynth" mit Plugin, Presets, Beispieltoenen und Hilfe. Eigene Presets und Toene bleiben erhalten. Entfernen: Windows-Einstellungen > Apps.'
$hint = Add-Label $HintNew 16 244
$hint.Size = New-Object System.Drawing.Size(608, 44)

$go = New-Object System.Windows.Forms.Button
$go.Text = 'Installieren'; $go.Location = New-Object System.Drawing.Point(408, 350); $go.Size = New-Object System.Drawing.Size(110, 32)
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Abbrechen'; $cancel.Location = New-Object System.Drawing.Point(526, 350); $cancel.Size = New-Object System.Drawing.Size(98, 32)

# Online-Update: neueste Version auf GitHub
$onl = Add-Label 'Online: wird geprueft ...' 16 300 380
$upd = New-Object System.Windows.Forms.Button
$upd.Text = 'Online-Update'; $upd.Location = New-Object System.Drawing.Point(408, 296); $upd.Size = New-Object System.Drawing.Size(216, 30)
$upd.Enabled = $false
$f.Controls.Add($upd)
$script:Latest = $null
$f.Add_Shown({
  $f.Refresh()
  try {
    $script:Latest = Get-LatestRelease
    $inst = Get-InstalledVersion
    if (Test-Newer $script:Latest.Version $inst) {
      $onl.Text = "Neue Version $($script:Latest.Version) verfuegbar" + $(if ($inst) { " (installiert: $inst)" } else { '' })
      $upd.Enabled = [bool]$inst
      if (-not $inst) { $onl.Text += ' - erst einmal normal installieren' }
      elseif ($StartUpdate) { $upd.PerformClick() }      # Klick auf den Hinweis im Plugin: gleich fragen
    } else {
      $onl.Text = "Aktuell: Version $inst ist die neueste."
    }
  } catch {
    $onl.Text = 'Online-Pruefung nicht moeglich (keine Verbindung?)'
  }
})
$upd.Add_Click({
  if (-not $script:Latest) { return }
  $msg = "Version $($script:Latest.Version) von GitHub laden und installieren?`r`n`r`n" +
    "Die installierten Plattformen werden mit derselben Auswahl aktualisiert. Eigene Presets und Toene bleiben erhalten.`r`n`r`n" +
    "Bitte die DAW vorher schliessen."
  if ([System.Windows.Forms.MessageBox]::Show($msg, 'GranularSynth Online-Update', 'YesNo', 'Question') -ne 'Yes') { return }
  $f.Cursor = 'WaitCursor'; $upd.Enabled = $false; $onl.Text = 'Lade und installiere ...'; $f.Refresh()
  try {
    $log = Invoke-OnlineUpdate $script:Latest
    [System.Windows.Forms.MessageBox]::Show("Update auf Version $($script:Latest.Version) fertig:`r`n`r`n" + ($log -join "`r`n") +
      "`r`n`r`nIn der DAW danach neu nach Plugins suchen.", 'GranularSynth') | Out-Null
    $f.Close()
  } catch {
    $f.Cursor = 'Default'; $upd.Enabled = $true; $onl.Text = 'Update fehlgeschlagen.'
    [System.Windows.Forms.MessageBox]::Show("Fehler: $($_.Exception.Message)", 'GranularSynth', 'OK', 'Error') | Out-Null
  }
})
$f.Controls.AddRange(@($c2, $t2, $b2, $c3, $t3, $b3, $ch, $go, $cancel))

function Update-Defaults {
  $p = if ($r64.Checked) { 'Win64' } else { 'Win32' }
  $e = Get-Installed $p
  if ($e) {
    # schon installiert: dieselbe Auswahl und dieselben Ordner vorschlagen (Update)
    $c2.Checked = $e.Vst2 -eq 1; $c3.Checked = $e.Vst3 -eq 1; $ch.Checked = $e.TestHost -eq 1
    $t2.Text = if ($e.Vst2Dir) { $e.Vst2Dir } else { Get-Vst2Default $p }
    $t3.Text = if ($e.Vst3Dir) { $e.Vst3Dir } else { Get-Vst3Default $p }
    $go.Text = 'Aktualisieren'
    $hint.Text = "Installiert ist Version $($e.DisplayVersion) - die Auswahl von damals ist vorgeschlagen. " +
      'Eigene Presets und Toene bleiben erhalten.'
  } else {
    $t2.Text = Get-Vst2Default $p
    $t3.Text = Get-Vst3Default $p
    $go.Text = 'Installieren'
    $hint.Text = $HintNew
  }
}
$r64.Add_CheckedChanged({ Update-Defaults })
Update-Defaults

$pick = {
  param($box)
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.SelectedPath = $box.Text
  if ($dlg.ShowDialog() -eq 'OK') { $box.Text = $dlg.SelectedPath }
}
$b2.Add_Click({ & $pick $t2 })
$b3.Add_Click({ & $pick $t3 })
$cancel.Add_Click({ $f.Close() })
$go.Add_Click({
  if (-not $c2.Checked -and -not $c3.Checked) {
    [System.Windows.Forms.MessageBox]::Show('Bitte VST2 und/oder VST3 waehlen.', 'GranularSynth') | Out-Null
    return
  }
  try {
    $p = if ($r64.Checked) { 'Win64' } else { 'Win32' }
    # Update: abgewaehlte oder verschobene Teile nicht stillschweigend loeschen, sondern fragen
    $e = Get-Installed $p
    $old = New-Object System.Collections.Generic.List[string]
    if ($e -and $e.Vst2 -eq 1 -and (-not $c2.Checked -or $e.Vst2Dir -ne $t2.Text)) { $old.Add((Join-Path $e.Vst2Dir 'GranularSynth')) }
    if ($e -and $e.Vst3 -eq 1 -and (-not $c3.Checked -or $e.Vst3Dir -ne $t3.Text)) { $old.Add((Join-Path $e.Vst3Dir 'GranularSynth')) }
    $log = Install-Granular $p $c2.Checked $c3.Checked $ch.Checked $t2.Text $t3.Text
    foreach ($o in $old) {
      if ((Test-Path $o) -and [System.Windows.Forms.MessageBox]::Show(
          "Die bisherige Installation in`r`n$o`r`nwird nicht mehr gebraucht. Mitgelieferte Dateien dort entfernen?`r`n(Eigene Presets und Toene bleiben.)",
          'GranularSynth', 'YesNo', 'Question') -eq 'Yes') {
        $l2 = New-Object System.Collections.Generic.List[string]
        Remove-Target $o $true $l2
        $log += $l2
      }
    }
    $msg = "Installiert ($p):`r`n`r`n" + ($log -join "`r`n") +
      "`r`n`r`nIn FL Studio danach: Options > Manage plugins > Find plugins."
    [System.Windows.Forms.MessageBox]::Show($msg, 'GranularSynth') | Out-Null
    $f.Close()
  } catch {
    [System.Windows.Forms.MessageBox]::Show("Fehler: $($_.Exception.Message)", 'GranularSynth', 'OK', 'Error') | Out-Null
  }
})
[void]$f.ShowDialog()
