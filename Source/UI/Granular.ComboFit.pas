{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.ComboFit;

{ Aufklappliste einer ComboBox so breit machen, dass jeder Eintrag vollstaendig lesbar ist
  (CB_SETDROPPEDWIDTH). Wird beim Aufklappen gemessen, damit auch spaeter geaenderte
  Eintraege (Presets, Geraete) passen. Das geschlossene Feld behaelt seine Breite. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.Classes, Vcl.StdCtrls;

procedure EnableComboFit(C: TComboBox);

implementation

type
  TComboFitter = class
    procedure DropDown(Sender: TObject);
  end;

var
  Fitter: TComboFitter;

procedure TComboFitter.DropDown(Sender: TObject);
var
  C: TComboBox;
  I, W, Mx: Integer;
begin
  C := Sender as TComboBox;
  C.Canvas.Font := C.Font;
  Mx := C.Width;
  for I := 0 to C.Items.Count - 1 do
  begin
    W := C.Canvas.TextWidth(C.Items[I]) + 12;
    if W > Mx then
      Mx := W;
  end;
  if C.Items.Count > C.DropDownCount then
    Inc(Mx, GetSystemMetrics(SM_CXVSCROLL));
  SendMessage(C.Handle, CB_SETDROPPEDWIDTH, Mx, 0);
end;

procedure EnableComboFit(C: TComboBox);
begin
  C.OnDropDown := Fitter.DropDown;
end;

initialization
  Fitter := TComboFitter.Create;
finalization
  Fitter.Free;
end.
