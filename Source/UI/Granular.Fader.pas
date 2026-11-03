{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Fader;

{ Schieberegler im Stil eines DJ-Mixer-Kanals: schwarzer Griff mit Querrillen und heller Markierung,
  vertiefter Schlitz als Bahn. Nur die Darstellung aendert sich (Custom-Draw des Windows-Steuerelements),
  Bedienung (Maus, Touchpad, Tastatur) bleibt die des normalen Trackbars.
  Einbindung: Unit NACH Vcl.ComCtrls/Vcl.StdCtrls in die uses aufnehmen - die Klassen hier ueberdecken die
  der VCL, alle vorhandenen .Create bekommen so den neuen Look ohne weitere Aenderung.
  Ausserdem: TButton und TComboBox in dunklem gebuerstetem Aluminium (Auswahl in der Liste bernsteinfarben),
  TCheckBox als Kippschalter (an = Hebel oben, rote Lampe), TPageControl mit dunklem
  Metallrahmen statt des weissen Windows-Rahmens. }

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.CommCtrl, System.Classes, Vcl.Controls, Vcl.ComCtrls, Vcl.StdCtrls,
  Vcl.Graphics, Vcl.Forms, Granular.IconButton;

type
  { Tooltip ohne Schlagschatten: Windows laesst den Schatten (CS_DROPSHADOW) eines Tooltips manchmal als
    grauen Strich auf dem Bildschirm stehen, wenn das Fenster beim Ein-/Ausblenden zerstoert wird
    (Plugin-Fenster zu, Host beendet). Ohne Schatten kann nichts haengen bleiben; passt zum flachen Stil. }
  TFlatHintWindow = class(THintWindow)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

  TModWheelEvent = procedure(Sender: TObject; Delta: Integer) of object;

  { Modulation am Regler: je Matrix-Zeile, die auf den Regler wirkt, eine eigene duenne Spur in eigener
    Farbe (MOD_LANE_COLORS), Laenge = Menge in Anteilen des Regelwegs ab dem Griff (-1..1).
    Alt + Mausrad meldet sich ueber OnModWheel statt den Regler zu bewegen. }
  TTrackBar = class(Vcl.ComCtrls.TTrackBar)
  private
    FModN: Integer;
    FModD: array[0..3] of Single;
    FOnModWheel: TModWheelEvent;
    procedure CNNotify(var Message: TWMNotifyTRB); message CN_NOTIFY;
    procedure TBMSetPos(var Message: TMessage); message TBM_SETPOS;
    procedure DrawChannel(DC: HDC; R: TRect);
    procedure DrawThumb(DC: HDC; R: TRect);
  protected
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Changed; override;
  public
    { Mengen der Zeilen (hoechstens 4 werden gezeichnet); leeres Feld = keine Modulation }
    procedure SetModDepths(const Depths: array of Single);
    property OnModWheel: TModWheelEvent read FOnModWheel write FOnModWheel;
  end;

const
  // Farben der Modulationsspuren (BGR) und ihre Namen fuer Menue/Statuszeile
  MOD_LANE_COLORS: array[0..3] of TColor = ($00D0B030, $003090F0, $00C050D0, $0030D0A0);
  MOD_LANE_NAMES: array[0..3] of string = ('türkis', 'orange', 'magenta', 'gelbgrün');

type

  { Kippschalter: Mutter (Ring) mit Hebel; an = Hebel nach oben, Spitze leuchtet rot; aus = Hebel kippt
    nach unten, Spitze dunkel. Beschriftung (falls vorhanden) rechts daneben in der Schriftfarbe. }
  { Owner-Draw (BS_OWNERDRAW) statt Custom-Draw: funktioniert auch, wenn die DAW das Plugin ohne die
    modernen Windows-Steuerelemente (ComCtl 6) laedt. Klick schaltet weiter ueber die VCL (BN_CLICKED). }
  TCheckBox = class(Vcl.StdCtrls.TCheckBox)
  private
    procedure CNDrawItem(var Message: TWMDrawItem); message CN_DRAWITEM;
    procedure BMSetCheck(var Message: TMessage); message BM_SETCHECK;
    procedure DrawSwitch(DC: HDC; const R: TRect);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

  { Knopf aus gebuerstetem Aluminium (dunkel), Schrift fast schwarz; heller unter der Maus, gedrueckt dunkler }
  TButton = class(Vcl.StdCtrls.TButton)
  private
    FHot: Boolean;
    FActive: Boolean;
    FGlyph: Integer;
    FIcon: TEdIcon;
    FIconOnly: Boolean;
    procedure SetActive(Value: Boolean);
    procedure SetIcon(Value: TEdIcon);
    procedure CNDrawItem(var Message: TWMDrawItem); message CN_DRAWITEM;
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure SetButtonStyle(ADefault: Boolean); override;
  public
    { hervorgehoben (bernsteinfarben): gewaehlte Seite eines Umschalters }
    property Active: Boolean read FActive write SetActive;
    { Symbol statt Text: 0 = keins, 1 = Papierkorb (die Beschriftung bleibt fuer Tooltip/Barrierefreiheit) }
    property Glyph: Integer read FGlyph write FGlyph;
    { Symbol links neben dem Text; passt beides nicht hinein, bleibt nur der Text (nie abgeschnitten) }
    property Icon: TEdIcon read FIcon write SetIcon;
    { nur das Symbol zeigen (Beschriftung bleibt fuer Tooltip/Barrierefreiheit) }
    property IconOnly: Boolean read FIconOnly write FIconOnly;
  end;

  { Aufklappliste: geschlossenes Feld in gebuerstetem Aluminium (selbst gezeichnet), Liste dunkel mit
    bernsteinfarbener Auswahl (Owner-Draw). Eingabefelder (csDropDown) bekommen nur die Farben. }
  TComboBox = class(Vcl.StdCtrls.TComboBox)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DrawItem(Index: Integer; Rect: TRect; State: TOwnerDrawState); override;
  private
    procedure WMPaint(var Message: TWMPaint); message WM_PAINT;
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure PaintEditFrame;
  end;

  { Eingabefeld: weisser Windows-Rand wird durch einen Metallrand ersetzt }
  TEdit = class(Vcl.StdCtrls.TEdit)
  private
    procedure WMNCPaint(var Message: TWMNCPaint); message WM_NCPAINT;
  protected
    procedure CreateWnd; override;
  end;

  { Reiter: der weisse Rahmen um die Seite wird nach dem Zeichnen durch einen dunklen Metallrahmen ersetzt }
  TPageControl = class(Vcl.ComCtrls.TPageControl)
  private
    procedure WMPaint(var Message: TWMPaint); message WM_PAINT;
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
  public
    procedure InvalidateTabs;
  protected
    procedure Change; override;
  end;

implementation

uses
  System.Math, System.SysUtils;

procedure TFlatHintWindow.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.WindowClass.style := Params.WindowClass.style and not CS_DROPSHADOW;
end;


procedure FillRectColor(DC: HDC; const R: TRect; C: TColor);
var
  Br: HBRUSH;
begin
  Br := CreateSolidBrush(ColorToRGB(C));
  FillRect(DC, R, Br);
  DeleteObject(Br);
end;

procedure LineColor(DC: HDC; X1, Y1, X2, Y2: Integer; C: TColor);
var
  Pen, Old: HPEN;
begin
  Pen := CreatePen(PS_SOLID, 1, ColorToRGB(C));
  Old := SelectObject(DC, Pen);
  MoveToEx(DC, X1, Y1, nil);
  LineTo(DC, X2, Y2);
  SelectObject(DC, Old);
  DeleteObject(Pen);
end;

function Mix(A, B: TColor; T: Double): TColor;
var
  Ca, Cb: Cardinal;
begin
  Ca := ColorToRGB(A); Cb := ColorToRGB(B);
  Result := RGB(Round(GetRValue(Ca) + (GetRValue(Cb) - GetRValue(Ca)) * T),
                Round(GetGValue(Ca) + (GetGValue(Cb) - GetGValue(Ca)) * T),
                Round(GetBValue(Ca) + (GetBValue(Cb) - GetBValue(Ca)) * T));
end;

{ Bahn: schmaler, vertiefter Schlitz (oben/links dunkle Kante, unten/rechts helle Kante) }
procedure TTrackBar.DrawChannel(DC: HDC; R: TRect);
var
  C, A, B, I, Off: Integer;
  F: Double;
begin
  if Orientation = trHorizontal then
  begin
    C := (R.Top + R.Bottom) div 2;
    R := Rect(R.Left, C - 2, R.Right, C + 2);
  end
  else
  begin
    C := (R.Left + R.Right) div 2;
    R := Rect(C - 2, R.Top, C + 2, R.Bottom);
  end;
  FillRectColor(DC, R, $00141414);
  LineColor(DC, R.Left, R.Top, R.Right, R.Top, $00080808);
  LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, $00080808);
  LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, $00505050);
  LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, $00505050);
  if (FModN > 0) and (Max > Min) then
  begin
    // je Zeile eine 2 px breite Spur nebeneinander, vom Griff aus in Richtung hoeherer Werte
    // (waagerecht nach rechts, senkrecht nach oben)
    F := (Position - Min) / (Max - Min);
    for I := 0 to FModN - 1 do
    begin
      Off := (I - FModN div 2) * 2;
      if Orientation = trHorizontal then
      begin
        A := R.Left + Round(F * (R.Right - R.Left));
        B := EnsureRange(A + Round(FModD[I] * (R.Right - R.Left)), R.Left, R.Right);
        C := (R.Top + R.Bottom) div 2 + Off;
        FillRectColor(DC, Rect(System.Math.Min(A, B), C - 1, System.Math.Max(A, B) + 1, C + 1), MOD_LANE_COLORS[I]);
      end
      else
      begin
        A := R.Top + Round(F * (R.Bottom - R.Top));
        B := EnsureRange(A - Round(FModD[I] * (R.Bottom - R.Top)), R.Top, R.Bottom);
        C := (R.Left + R.Right) div 2 + Off;
        FillRectColor(DC, Rect(C - 1, System.Math.Min(A, B), C + 1, System.Math.Max(A, B) + 1), MOD_LANE_COLORS[I]);
      end;
    end;
  end;
end;

procedure TTrackBar.SetModDepths(const Depths: array of Single);
var
  I, N: Integer;
  Same: Boolean;
begin
  N := System.Math.Min(Length(Depths), 4);
  Same := N = FModN;
  for I := 0 to N - 1 do
    if Same and (Abs(EnsureRange(Depths[I], -1, 1) - FModD[I]) >= 0.001) then
      Same := False;
  if Same then
    Exit;
  FModN := N;
  for I := 0 to N - 1 do
    FModD[I] := EnsureRange(Depths[I], -1, 1);
  if HandleAllocated then
    Invalidate;
end;

{ Windows zeichnet beim Verschieben nur den Bereich um den Griff neu - mit Spuren muss der ganze Regler
  neu gezeichnet werden, sonst bleiben Reste der alten Spur stehen }
procedure TTrackBar.Changed;
begin
  inherited;
  if (FModN > 0) and HandleAllocated then
    Invalidate;
end;

procedure TTrackBar.TBMSetPos(var Message: TMessage);
begin
  inherited;
  if (FModN > 0) and HandleAllocated then
    Invalidate;
end;

function TTrackBar.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if (ssAlt in Shift) and Assigned(FOnModWheel) then
  begin
    FOnModWheel(Self, WheelDelta);
    Result := True;
  end
  else
    Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
end;

{ Griff: Kappe eines Mixer-Faders. Laengsachse quer zur Bahn; Rillen parallel zur Laengsachse,
  in der Mitte eine helle Markierung. Waagerechte Regler: gedreht. }
procedure TTrackBar.DrawThumb(DC: HDC; R: TRect);
var
  Horz: Boolean;
  I, N, Len, Thick, P, Mid: Integer;
  Base, Hi, Lo, Ridge, Mark: TColor;
  RR: TRect;
begin
  Horz := Orientation = trHorizontal;
  if Enabled then
  begin
    Base := $00262626; Hi := $00585858; Lo := $00101010; Ridge := $00141414; Mark := $00F0F0F0;
  end
  else
  begin
    Base := $00404040; Hi := $00606060; Lo := $00303030; Ridge := $00383838; Mark := $00909090;
  end;
  // Koerper mit leichtem Verlauf (oben/links heller = Glanz)
  if Horz then Thick := R.Width else Thick := R.Height;
  if Horz then Len := R.Height else Len := R.Width;
  for I := 0 to Thick - 1 do
  begin
    if Horz then
      RR := Rect(R.Left + I, R.Top, R.Left + I + 1, R.Bottom)
    else
      RR := Rect(R.Left, R.Top + I, R.Right, R.Top + I + 1);
    FillRectColor(DC, RR, Mix(Hi, Base, EnsureRange(I / (Thick * 0.45 + 1), 0.0, 1.0)));
  end;
  // Rand
  LineColor(DC, R.Left, R.Top, R.Right - 1, R.Top, Hi);
  LineColor(DC, R.Left, R.Top, R.Left, R.Bottom - 1, Hi);
  LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, Lo);
  LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, Lo);
  // Querrillen (Griffigkeit), Abstand 2 px, mit hellem Grat darunter
  N := (Thick - 4) div 2;
  for I := 0 to N - 1 do
  begin
    P := 2 + I * 2;
    if Horz then
    begin
      LineColor(DC, R.Left + P, R.Top + 2, R.Left + P, R.Bottom - 2, Ridge);
    end
    else
    begin
      LineColor(DC, R.Left + 2, R.Top + P, R.Right - 2, R.Top + P, Ridge);
    end;
  end;
  // Markierung in der Mitte (zeigt die Stellung genau an)
  if Horz then
  begin
    Mid := (R.Left + R.Right) div 2;
    LineColor(DC, Mid, R.Top + 1, Mid, R.Bottom - 1, Mark);
  end
  else
  begin
    Mid := (R.Top + R.Bottom) div 2;
    LineColor(DC, R.Left + 1, Mid, R.Right - 1, Mid, Mark);
  end;
  if Len = 0 then Exit;
end;

type
  TControlAccess = class(TControl);

function IfThenInt(B: Boolean; T, F: Integer): Integer;
begin
  if B then Result := T else Result := F;
end;

procedure Ellipse0(DC: HDC; X, Y, Rad: Integer; Fill, Edge: TColor);
var
  Br: HBRUSH;
  Pen: HPEN;
  OB: HGDIOBJ;
  OP: HGDIOBJ;
begin
  Br := CreateSolidBrush(ColorToRGB(Fill));
  Pen := CreatePen(PS_SOLID, 1, ColorToRGB(Edge));
  OB := SelectObject(DC, Br);
  OP := SelectObject(DC, Pen);
  Winapi.Windows.Ellipse(DC, X - Rad, Y - Rad, X + Rad + 1, Y + Rad + 1);
  SelectObject(DC, OB);
  SelectObject(DC, OP);
  DeleteObject(Br);
  DeleteObject(Pen);
end;

procedure ThickLine(DC: HDC; X1, Y1, X2, Y2, W: Integer; C: TColor);
var
  Pen, Old: HPEN;
begin
  Pen := CreatePen(PS_SOLID, W, ColorToRGB(C));
  Old := SelectObject(DC, Pen);
  MoveToEx(DC, X1, Y1, nil);
  LineTo(DC, X2, Y2);
  SelectObject(DC, Old);
  DeleteObject(Pen);
end;

procedure TCheckBox.DrawSwitch(DC: HDC; const R: TRect);
var
  Bg: TColor;
  Cx, Cy, S, Tip: Integer;
  On_: Boolean;
  TR: TRect;
  Txt: string;
  OldF: HFONT;
begin
  if Parent <> nil then Bg := TControlAccess(Parent).Color else Bg := clBtnFace;
  FillRectColor(DC, R, Bg);
  On_ := Checked;
  S := Min(R.Height, 24);
  Cx := R.Left + S div 2;
  Cy := (R.Top + R.Bottom) div 2;
  // Platte + Mutter
  Ellipse0(DC, Cx, Cy, S div 2 - 1, $00282828, $00606060);
  Ellipse0(DC, Cx, Cy, S div 5, $00A0A0A0, $00505050);
  // Hebel: an = nach oben, aus = nach unten (perspektivisch kuerzer, zeigt Richtung)
  if On_ then Tip := Cy - (S div 2 - 4) else Tip := Cy + (S div 2 - 4);
  ThickLine(DC, Cx, Cy, Cx, Tip, 3, $00C8C8C8);
  ThickLine(DC, Cx - 1, Cy, Cx - 1, Tip, 1, $00F0F0F0);
  if On_ and Enabled then
  begin
    Ellipse0(DC, Cx, Tip, S div 6 + 1, $002828C0, $002020A0);    // Leuchten (Schein)
    Ellipse0(DC, Cx, Tip, S div 6, $003838FF, $004848FF);        // rote Spitze
    Ellipse0(DC, Cx - 1, Tip - 1, 0, $00C0C0FF, $00C0C0FF);
  end
  else
    Ellipse0(DC, Cx, Tip, S div 6, $00585858, $00202020);    // aus: dunkle Spitze
  // Beschriftung
  Txt := Caption;
  if Txt <> '' then
  begin
    TR := Rect(R.Left + S + 4, R.Top, R.Right, R.Bottom);
    SetBkMode(DC, TRANSPARENT);
    if Enabled then SetTextColor(DC, ColorToRGB(Font.Color)) else SetTextColor(DC, $00808080);
    OldF := SelectObject(DC, Font.Handle);
    DrawText(DC, PChar(Txt), Length(Txt), TR, DT_LEFT or DT_VCENTER or DT_SINGLELINE);
    SelectObject(DC, OldF);
  end;
end;

procedure TCheckBox.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := (Params.Style and not $F) or BS_OWNERDRAW   // $F = BS_TYPEMASK;
end;

procedure TCheckBox.CNDrawItem(var Message: TWMDrawItem);
begin
  DrawSwitch(Message.DrawItemStruct.hDC, Message.DrawItemStruct.rcItem);
  Message.Result := 1;
end;

{ Zustand geaendert (Klick oder Checked := ...): Owner-Draw-Knoepfe zeichnen das nicht selbst neu }
procedure TCheckBox.BMSetCheck(var Message: TMessage);
begin
  inherited;
  Invalidate;
end;

const
  ALU_BASE = $00807C78;      // dunkles Aluminium (BGR)
  ACTIVE_BASE = $0048A8D8;   // bernsteinfarbenes Aluminium (BGR): gewaehlter Umschalter
  ALU_TEXT = $00101010;
  LIST_BG = $00302C2A;
  LIST_TEXT = $00DCDCDC;
  LIST_SEL = $0040A8E0;      // Bernstein wie die Ueberschriften
  LIST_SEL_TEXT = $00101010;
  { Stil der Knoepfe, Listen, Eingabefelder und Reiter: True = flach und dunkel (Rand fein, Bernstein als
    Akzent), False = gebuerstetes Aluminium (bisheriger Stil) }
  FLAT_UI = True;
  FLAT_FACE = $00403A37;     // Flaeche (BGR)
  FLAT_HOT = $004C4642;      // unter der Maus
  FLAT_DOWN = $00302B29;     // gedrueckt
  FLAT_BORDER = $00605954;
  FLAT_TEXT = $00E2DED9;
  FLAT_DIM = $00787370;      // gesperrt
  FLAT_ACT_FACE = $00284C66; // gewaehlter Umschalter: gedecktes Bernstein
  FLAT_ACT_TEXT = $0070D0F8;
  FLAT_TAB_OFF = $002E2A28;  // Reiter nicht gewaehlt

{ gebuerstetes Aluminium: feine waagrechte Striche (je Zeile leicht andere Helligkeit, fest verteilt),
  oben etwas heller (Licht von oben), Rand dunkel mit heller Oberkante }
function IfThenColor(Cond: Boolean; A, B: TColor): TColor;
begin
  if Cond then Result := A else Result := B;
end;

procedure DrawBrushed(DC: HDC; const R: TRect; Base: TColor; Lift: Integer);
var
  Y, H, D: Integer;
  C: Cardinal;
  Rb, Gb, Bb: Integer;
begin
  C := ColorToRGB(Base);
  H := Max(1, R.Height);
  for Y := R.Top to R.Bottom - 1 do
  begin
    // Streifen: fester Pseudozufall je Zeile (+-7), dazu Verlauf von oben (+12) nach unten (-8)
    D := Integer((Cardinal(Y * 1103515245 + 12345) shr 16) mod 15) - 7 +
      Round(12 - 20 * (Y - R.Top) / H) + Lift;
    Rb := EnsureRange(GetRValue(C) + D, 0, 255);
    Gb := EnsureRange(GetGValue(C) + D, 0, 255);
    Bb := EnsureRange(GetBValue(C) + D, 0, 255);
    FillRectColor(DC, Rect(R.Left, Y, R.Right, Y + 1), RGB(Rb, Gb, Bb));
  end;
  LineColor(DC, R.Left, R.Top, R.Right, R.Top, $00B8B4B0);
  LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, $00303030);
  LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, $00505050);
  LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, $00303030);
end;

{ flache Flaeche mit 1-Pixel-Rand }
procedure DrawFlat(DC: HDC; const R: TRect; Face, Border: TColor);
begin
  FillRectColor(DC, R, Face);
  LineColor(DC, R.Left, R.Top, R.Right, R.Top, Border);
  LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, Border);
  LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, Border);
  LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, Border);
end;

{ schmaler Winkel (Chevron) nach unten als Listenpfeil }
procedure DrawChevron(DC: HDC; Cx, Cy: Integer; C: TColor);
var
  I: Integer;
begin
  for I := 0 to 3 do
  begin
    LineColor(DC, Cx - 4 + I, Cy - 2 + I, Cx - 2 + I, Cy - 2 + I, C);
    LineColor(DC, Cx + 3 - I, Cy - 2 + I, Cx + 5 - I, Cy - 2 + I, C);
  end;
end;

procedure TButton.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := (Params.Style and not $F) or BS_OWNERDRAW   // $F = BS_TYPEMASK;
end;

{ die VCL setzt beim Fokuswechsel BS_PUSHBUTTON/BS_DEFPUSHBUTTON - das wuerde Owner-Draw abschalten }
procedure TButton.SetButtonStyle(ADefault: Boolean);
begin
  Invalidate;
end;

procedure TButton.SetIcon(Value: TEdIcon);
begin
  if FIcon <> Value then
  begin
    FIcon := Value;
    Invalidate;
  end;
end;

procedure TButton.CMMouseEnter(var Message: TMessage);
begin
  inherited;
  FHot := True;
  Invalidate;
end;

procedure TButton.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FHot := False;
  Invalidate;
end;

procedure TButton.SetActive(Value: Boolean);
begin
  if FActive = Value then
    Exit;
  FActive := Value;
  if HandleAllocated then
    Invalidate;
end;

procedure TButton.CNDrawItem(var Message: TWMDrawItem);
var
  DS: PDrawItemStruct;
  R: TRect;
  Lift: Integer;
  Txt: string;
  OldF: HFONT;
  Down: Boolean;
  Cx, Cy: Integer;
  Gc: TColor;
  IS_: Integer;
  Ext: TSize;
begin
  DS := Message.DrawItemStruct;
  R := DS.rcItem;
  Down := DS.itemState and ODS_SELECTED <> 0;
  if Parent <> nil then
    FillRectColor(DS.hDC, R, TControlAccess(Parent).Color);
  InflateRect(R, -1, -1);
  Txt := Caption;
  SetBkMode(DS.hDC, TRANSPARENT);
  if FLAT_UI then
  begin
    if FActive then
      DrawFlat(DS.hDC, R, FLAT_ACT_FACE, LIST_SEL)
    else if Down then
      DrawFlat(DS.hDC, R, FLAT_DOWN, FLAT_BORDER)
    else if FHot then
      DrawFlat(DS.hDC, R, FLAT_HOT, $00807870)
    else
      DrawFlat(DS.hDC, R, FLAT_FACE, FLAT_BORDER);
    if not Enabled then SetTextColor(DS.hDC, FLAT_DIM)
    else if FActive then SetTextColor(DS.hDC, FLAT_ACT_TEXT)
    else SetTextColor(DS.hDC, FLAT_TEXT);
  end
  else
  begin
    Lift := 0;
    if FHot then Lift := 12;
    if Down then Lift := -18;
    if FActive then
      DrawBrushed(DS.hDC, R, ACTIVE_BASE, Lift)
    else
      DrawBrushed(DS.hDC, R, ALU_BASE, Lift);
    if Enabled then SetTextColor(DS.hDC, ALU_TEXT) else SetTextColor(DS.hDC, $00505050);
  end;
  if Down then OffsetRect(R, 1, 1);
  if FGlyph = 1 then
  begin
    // Papierkorb: Deckel mit Griff, Korpus mit drei Rillen
    Cx := (R.Left + R.Right) div 2;
    Cy := (R.Top + R.Bottom) div 2;
    if FHot and Enabled then Gc := LIST_SEL else if Enabled then Gc := FLAT_TEXT else Gc := FLAT_DIM;
    LineColor(DS.hDC, Cx - 5, Cy - 4, Cx + 6, Cy - 4, Gc);
    LineColor(DS.hDC, Cx - 1, Cy - 6, Cx + 2, Cy - 6, Gc);
    LineColor(DS.hDC, Cx - 4, Cy - 3, Cx - 4, Cy + 5, Gc);
    LineColor(DS.hDC, Cx + 4, Cy - 3, Cx + 4, Cy + 5, Gc);
    LineColor(DS.hDC, Cx - 4, Cy + 5, Cx + 5, Cy + 5, Gc);
    LineColor(DS.hDC, Cx - 2, Cy - 2, Cx - 2, Cy + 4, Gc);
    LineColor(DS.hDC, Cx, Cy - 2, Cx, Cy + 4, Gc);
    LineColor(DS.hDC, Cx + 2, Cy - 2, Cx + 2, Cy + 4, Gc);
    Message.Result := 1;
    Exit;
  end;
  OldF := SelectObject(DS.hDC, Font.Handle);
  if FIcon <> eiNone then
  begin
    IS_ := Min(16, R.Bottom - R.Top - 6);
    GetTextExtentPoint32(DS.hDC, PChar(Txt), Length(Txt), Ext);
    if FIconOnly or (Txt = '') then
    begin
      PaintIcon(DS.hDC, (R.Left + R.Right - IS_) div 2, (R.Top + R.Bottom - IS_) div 2, IS_, FIcon, FActive,
        not Enabled, FHot and Enabled);
      SelectObject(DS.hDC, OldF);
      Message.Result := 1;
      Exit;
    end;
    // Symbol + Abstand + Text mittig, wenn es passt (sonst etwas kleiner, sonst nur Text)
    if IS_ + 4 + Ext.cx > R.Right - R.Left - 4 then
      IS_ := 13;
    if IS_ + 4 + Ext.cx <= R.Right - R.Left - 4 then
    begin
      Cx := (R.Left + R.Right - (IS_ + 4 + Ext.cx)) div 2;
      PaintIcon(DS.hDC, Cx, (R.Top + R.Bottom - IS_) div 2, IS_, FIcon, FActive, not Enabled, False);
      R.Left := Cx + IS_ + 4;
      DrawText(DS.hDC, PChar(Txt), Length(Txt), R, DT_LEFT or DT_VCENTER or DT_SINGLELINE);
      SelectObject(DS.hDC, OldF);
      Message.Result := 1;
      Exit;
    end;
  end;
  DrawText(DS.hDC, PChar(Txt), Length(Txt), R, DT_CENTER or DT_VCENTER or DT_SINGLELINE);
  SelectObject(DS.hDC, OldF);
  Message.Result := 1;
end;

procedure TComboBox.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // Liste selbst zeichnen (dunkel, bernsteinfarbene Auswahl)
  if Style in [csDropDown, csDropDownList] then
    Params.Style := Params.Style or CBS_OWNERDRAWFIXED or CBS_HASSTRINGS;
end;

{ Rand der aufgeklappten Liste: Windows zeichnet ihn blau (Akzentfarbe) - nach dem Rahmen-Zeichnen
  metallisch uebermalen (aussen hell, innen dunkel) }
function ListFrameProc(hWnd: HWND; uMsg: UINT; wParam: WPARAM; lParam: LPARAM; uIdSubclass: UINT_PTR;
  dwRefData: DWORD_PTR): LRESULT; stdcall;
var
  DC: HDC;
  R: TRect;
begin
  Result := DefSubclassProc(hWnd, uMsg, wParam, lParam);
  if uMsg = WM_NCPAINT then
  begin
    DC := GetWindowDC(hWnd);
    try
      GetWindowRect(hWnd, R);
      OffsetRect(R, -R.Left, -R.Top);
      LineColor(DC, R.Left, R.Top, R.Right, R.Top, $00909090);
      LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, $00909090);
      LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, $00505050);
      LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, $00505050);
    finally
      ReleaseDC(hWnd, DC);
    end;
  end
  else if uMsg = WM_NCDESTROY then
    RemoveWindowSubclass(hWnd, @ListFrameProc, 1);
end;

procedure TEdit.CreateWnd;
begin
  inherited;
  if FLAT_UI then
  begin
    if Color <> FLAT_FACE then Color := FLAT_FACE;
    if Font.Color <> FLAT_TEXT then Font.Color := FLAT_TEXT;
  end;
end;

procedure TEdit.WMNCPaint(var Message: TWMNCPaint);
var
  DC: HDC;
  R: TRect;
begin
  inherited;
  DC := GetWindowDC(Handle);
  try
    GetWindowRect(Handle, R);
    OffsetRect(R, -R.Left, -R.Top);
    if FLAT_UI then
    begin
      LineColor(DC, R.Left, R.Top, R.Right, R.Top, FLAT_BORDER);
      LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, FLAT_BORDER);
      LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, FLAT_BORDER);
      LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, FLAT_BORDER);
      InflateRect(R, -1, -1);
      LineColor(DC, R.Left, R.Top, R.Right, R.Top, ColorToRGB(Color));
      LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, ColorToRGB(Color));
      LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, ColorToRGB(Color));
      LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, ColorToRGB(Color));
      Exit;
    end;
    LineColor(DC, R.Left, R.Top, R.Right, R.Top, $00505050);
    LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, $00505050);
    LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, $00303030);
    LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, $00303030);
    InflateRect(R, -1, -1);                        // zweite Linie: Feldfarbe statt Weiss
    LineColor(DC, R.Left, R.Top, R.Right, R.Top, ColorToRGB(Color));
    LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, ColorToRGB(Color));
    LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, ColorToRGB(Color));
    LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, ColorToRGB(Color));
  finally
    ReleaseDC(Handle, DC);
  end;
end;

procedure TComboBox.CreateWnd;
var
  Info: TComboBoxInfo;
begin
  inherited;
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  if GetComboBoxInfo(Handle, Info) and (Info.hwndList <> 0) then
    SetWindowSubclass(Info.hwndList, @ListFrameProc, 1, 0);
  // Eingabefeld: Metallgrau statt Weiss - nur bei Abweichung setzen (jede Aenderung erzeugt sonst
  // Neuzeichnen bzw. bei der Schrift das Fenster neu, mit allen ~300 Eintraegen)
  if Style = csDropDown then
  begin
    if FLAT_UI then
    begin
      if Color <> FLAT_FACE then Color := FLAT_FACE;
      if Font.Color <> FLAT_TEXT then Font.Color := FLAT_TEXT;
    end
    else
    begin
      if Color <> $00A09C98 then Color := $00A09C98;
      if Font.Color <> ALU_TEXT then Font.Color := ALU_TEXT;
    end;
  end;
end;

procedure TComboBox.DrawItem(Index: Integer; Rect: TRect; State: TOwnerDrawState);
var
  Txt: string;
begin
  if odComboBoxEdit in State then
  begin
    // Eingabefeld-Teil (nur csDropDown sichtbar)
    if FLAT_UI then
    begin
      Canvas.Brush.Color := FLAT_FACE;
      Canvas.Font.Color := FLAT_TEXT;
    end
    else
    begin
      Canvas.Brush.Color := $00A09C98;
      Canvas.Font.Color := ALU_TEXT;
    end;
  end
  else if odSelected in State then
  begin
    Canvas.Brush.Color := LIST_SEL;
    Canvas.Font.Color := LIST_SEL_TEXT;
  end
  else
  begin
    Canvas.Brush.Color := LIST_BG;
    Canvas.Font.Color := LIST_TEXT;
  end;
  Canvas.FillRect(Rect);
  if (Index >= 0) and (Index < Items.Count) then
  begin
    Txt := Items[Index];
    Inc(Rect.Left, 3);
    DrawText(Canvas.Handle, PChar(Txt), Length(Txt), Rect, DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
  end;
end;

procedure TComboBox.PaintEditFrame;
var
  DC: HDC;
  R, E, B: TRect;
  Ax, Ay, I: Integer;
begin
  if not HandleAllocated or (EditHandle = 0) then Exit;
  R := ClientRect;
  GetWindowRect(EditHandle, E);
  MapWindowPoints(0, Handle, E, 2);
  DC := GetDC(Handle);
  try
    if FLAT_UI then
    begin
      FillRectColor(DC, Rect(R.Left, R.Top, R.Right, E.Top), FLAT_FACE);
      FillRectColor(DC, Rect(R.Left, E.Bottom, R.Right, R.Bottom), FLAT_FACE);
      FillRectColor(DC, Rect(R.Left, R.Top, E.Left, R.Bottom), FLAT_FACE);
      FillRectColor(DC, Rect(E.Right, R.Top, R.Right, R.Bottom), FLAT_FACE);
      LineColor(DC, R.Left, R.Top, R.Right, R.Top, FLAT_BORDER);
      LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, FLAT_BORDER);
      LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, FLAT_BORDER);
      LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, FLAT_BORDER);
      DrawChevron(DC, (E.Right + R.Right) div 2, (R.Top + R.Bottom) div 2, IfThenColor(Enabled, LIST_SEL, FLAT_DIM));
      Exit;
    end;
    // Rahmen zwischen Aussenkante und Edit (oben/unten/links)
    FillRectColor(DC, Rect(R.Left, R.Top, R.Right, E.Top), $00A09C98);
    FillRectColor(DC, Rect(R.Left, E.Bottom, R.Right, R.Bottom), $00A09C98);
    FillRectColor(DC, Rect(R.Left, R.Top, E.Left, R.Bottom), $00A09C98);
    LineColor(DC, R.Left, R.Top, R.Right, R.Top, $00505050);
    LineColor(DC, R.Left, R.Bottom - 1, R.Right, R.Bottom - 1, $00303030);
    LineColor(DC, R.Left, R.Top, R.Left, R.Bottom, $00505050);
    LineColor(DC, R.Right - 1, R.Top, R.Right - 1, R.Bottom, $00303030);
    // Pfeilknopf rechts vom Edit
    B := Rect(E.Right + 1, R.Top + 1, R.Right - 1, R.Bottom - 1);
    if B.Width > 4 then
    begin
      DrawBrushed(DC, B, ALU_BASE, 0);
      Ax := (B.Left + B.Right) div 2; Ay := (B.Top + B.Bottom) div 2 - 1;
      for I := 0 to 3 do
        LineColor(DC, Ax - 3 + I, Ay + I, Ax + 4 - I, Ay + I, $00202020);
    end;
  finally
    ReleaseDC(Handle, DC);
  end;
end;

procedure TComboBox.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  if Style = csDropDownList then
    Message.Result := 1
  else
    inherited;
end;

{ geschlossenes Feld (csDropDownList): Aluminium, Text des gewaehlten Eintrags, Pfeil rechts }
procedure TComboBox.WMPaint(var Message: TWMPaint);
var
  PS: TPaintStruct;
  DC: HDC;
  R, TR: TRect;
  Txt: string;
  OldF: HFONT;
  Ax, Ay, I: Integer;
begin
  if Style = csDropDown then
  begin
    // Eingabefeld: Windows zeichnet, danach Rand und Pfeilknopf (ausserhalb des Edit-Fensters) in Metall
    inherited;
    PaintEditFrame;
    Exit;
  end;
  if Style <> csDropDownList then
  begin
    inherited;
    Exit;
  end;
  if Message.DC = 0 then DC := BeginPaint(Handle, PS) else DC := Message.DC;
  try
    R := ClientRect;
    if Parent <> nil then
      FillRectColor(DC, R, TControlAccess(Parent).Color);
    if FLAT_UI then
    begin
      DrawFlat(DC, R, FLAT_FACE, IfThenColor(Focused or DroppedDown, LIST_SEL, FLAT_BORDER));
      DrawChevron(DC, R.Right - 10, (R.Top + R.Bottom) div 2, IfThenColor(Enabled, LIST_SEL, FLAT_DIM));
    end
    else
    begin
      DrawBrushed(DC, R, ALU_BASE, IfThenInt(Focused, 6, 0));
      // Pfeil
      Ax := R.Right - 10; Ay := (R.Top + R.Bottom) div 2 - 1;
      for I := 0 to 3 do
        LineColor(DC, Ax - 3 + I, Ay + I, Ax + 4 - I, Ay + I, $00202020);
      LineColor(DC, R.Right - 19, R.Top + 4, R.Right - 19, R.Bottom - 4, $00505050);
    end;
    // Text
    if ItemIndex >= 0 then Txt := Items[ItemIndex] else Txt := Text;
    TR := Rect(R.Left + 5, R.Top, R.Right - 22, R.Bottom);
    SetBkMode(DC, TRANSPARENT);
    if FLAT_UI then
    begin
      if Enabled then SetTextColor(DC, FLAT_TEXT) else SetTextColor(DC, FLAT_DIM);
    end
    else if Enabled then SetTextColor(DC, ALU_TEXT) else SetTextColor(DC, $00505050);
    OldF := SelectObject(DC, Font.Handle);
    DrawText(DC, PChar(Txt), Length(Txt), TR, DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);
    SelectObject(DC, OldF);
  finally
    if Message.DC = 0 then EndPaint(Handle, PS);
  end;
end;

{ komplett selbst gezeichnet: Reiter-Koepfe in dunklem Aluminium (aktiver Reiter heller, bernsteinfarbene
  Kante oben, Schrift bernstein), Leiste im Hintergrund der Umgebung, Seitenrahmen als Metallrahmen.
  Die Seiten selbst sind eigene Fenster und zeichnen sich wie bisher. }
procedure TPageControl.WMPaint(var Message: TWMPaint);
const
  RING: array[0..3] of TColor = ($00707070, $00484848, $003C3C3C, $00202020);
var
  PS: TPaintStruct;
  DC: HDC;
  D, O, R: TRect;
  I, J, Vis: Integer;
  Txt: string;
  OldF: HFONT;
  Act: Boolean;
  Bg: TColor;
begin
  if Message.DC = 0 then DC := BeginPaint(Handle, PS) else DC := Message.DC;
  try
    if Parent <> nil then Bg := TControlAccess(Parent).Color else Bg := clBtnFace;
    D := DisplayRect;
    O := Rect(0, D.Top - D.Left, ClientWidth, ClientHeight);
    // Leiste hinter den Reitern
    FillRectColor(DC, Rect(0, 0, ClientWidth, Max(0, O.Top)), Bg);
    // Seitenrahmen
    for I := 0 to D.Left - 1 do
      with Rect(O.Left + I, O.Top + I, O.Right - I, O.Bottom - I) do
      begin
        LineColor(DC, Left, Top, Right, Top, RING[Min(I, 3)]);
        LineColor(DC, Left, Bottom - 1, Right, Bottom - 1, RING[Min(I, 3)]);
        LineColor(DC, Left, Top, Left, Bottom, RING[Min(I, 3)]);
        LineColor(DC, Right - 1, Top, Right - 1, Bottom, RING[Min(I, 3)]);
      end;
    // Reiter
    SetBkMode(DC, TRANSPARENT);
    OldF := SelectObject(DC, Font.Handle);
    Vis := 0;
    for J := 0 to PageCount - 1 do
    begin
      if not Pages[J].TabVisible then Continue;
      R := TabRect(Vis);
      Inc(Vis);
      Act := Pages[J] = ActivePage;
      if FLAT_UI then
      begin
        if Act then
        begin
          Dec(R.Top, 2);
          Inc(R.Bottom, 1);
          DrawFlat(DC, R, Bg, FLAT_BORDER);
          LineColor(DC, R.Left + 1, R.Bottom - 1, R.Right - 1, R.Bottom - 1, Bg);   // offen zur Seite
          LineColor(DC, R.Left + 1, R.Top, R.Right - 1, R.Top, LIST_SEL);
          LineColor(DC, R.Left + 1, R.Top + 1, R.Right - 1, R.Top + 1, LIST_SEL);
          SetTextColor(DC, FLAT_ACT_TEXT);
        end
        else
        begin
          DrawFlat(DC, Rect(R.Left, R.Top, R.Right, R.Bottom), FLAT_TAB_OFF, $00403B38);
          SetTextColor(DC, $00B8B4B0);
        end;
      end
      else if Act then
      begin
        Dec(R.Top, 2);
        Inc(R.Bottom, 1);                         // aktiver Reiter verbindet sich mit dem Rahmen
        DrawBrushed(DC, R, $00888480, 14);
        LineColor(DC, R.Left + 1, R.Top, R.Right - 1, R.Top, LIST_SEL);
        LineColor(DC, R.Left + 1, R.Top + 1, R.Right - 1, R.Top + 1, LIST_SEL);
        SetTextColor(DC, ALU_TEXT);
      end
      else
      begin
        DrawBrushed(DC, R, $005C5854, 0);
        SetTextColor(DC, $00D8D8D8);
      end;
      Txt := Trim(Pages[J].Caption);
      DrawText(DC, PChar(Txt), Length(Txt), R, DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
    end;
    SelectObject(DC, OldF);
  finally
    if Message.DC = 0 then EndPaint(Handle, PS);
  end;
end;

{ Reiterwechsel: der aktive Reiter ist groesser gezeichnet als Windows ihn kennt - Windows erneuert nur
  die Standardflaechen, Reste des alten aktiven Reiters blieben stehen. Deshalb die ganze Reiterleiste
  neu zeichnen - per Klick (Change); Wechsel per Code: InvalidateTabs aufrufen (Editor.ShowPage). }
procedure TPageControl.InvalidateTabs;
var
  R: TRect;
begin
  if not HandleAllocated then Exit;
  R := Rect(0, 0, ClientWidth, DisplayRect.Top);
  InvalidateRect(Handle, @R, False);
end;

procedure TPageControl.Change;
begin
  inherited;
  InvalidateTabs;
end;

procedure TPageControl.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  Message.Result := 1;
end;

procedure TTrackBar.CNNotify(var Message: TWMNotifyTRB);
var
  CD: PNMCustomDraw;
begin
  if Message.NMHdr.code <> NM_CUSTOMDRAW then
  begin
    inherited;
    Exit;
  end;
  CD := PNMCustomDraw(Message.NMHdr);
  case CD.dwDrawStage of
    CDDS_PREPAINT:
      Message.Result := CDRF_NOTIFYITEMDRAW;
    CDDS_ITEMPREPAINT:
      case CD.dwItemSpec of
        TBCD_THUMB:
          begin
            DrawThumb(CD.hdc, CD.rc);
            Message.Result := CDRF_SKIPDEFAULT;
          end;
        TBCD_CHANNEL:
          begin
            DrawChannel(CD.hdc, CD.rc);
            Message.Result := CDRF_SKIPDEFAULT;
          end;
      else
        Message.Result := CDRF_DODEFAULT;
      end;
  else
    Message.Result := CDRF_DODEFAULT;
  end;
end;

initialization
  HintWindowClass := TFlatHintWindow;   // gilt fuer Plugin und Test-Host (vor dem ersten Tooltip)

end.
