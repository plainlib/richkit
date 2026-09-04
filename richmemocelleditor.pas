unit RichMemoCellEditor;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  StdCtrls,
  SysUtils,
  Grids,
  RichMemo;

type
  TRichMemoCellEditor = class(TRichMemo)
  private
    FGrid: TCustomGrid;
    FCol: Integer;
    FRow: Integer;
  protected
    procedure MsgSetGrid(var Msg: TGridMessage); message GM_SETGRID;
    procedure MsgSetPos(var Msg: TGridMessage); message GM_SETPOS;
    procedure MsgSetBounds(var Msg: TGridMessage); message GM_SETBOUNDS;
    procedure MsgSetValue(var Msg: TGridMessage); message GM_SETVALUE;
    procedure MsgGetValue(var Msg: TGridMessage); message GM_GETVALUE;
  end;

implementation

procedure TRichMemoCellEditor.MsgSetGrid(var Msg: TGridMessage);
begin
  FGrid := Msg.Grid;
  AutoSize := False;
  WordWrap := False;
  WantReturns := False;
  ScrollBars := ssNone;
end;

procedure TRichMemoCellEditor.MsgSetPos(var Msg: TGridMessage);
begin
  FCol := Msg.Col;
  FRow := Msg.Row;
end;

procedure TRichMemoCellEditor.MsgSetBounds(var Msg: TGridMessage);
begin
  with Msg.CellRect do
    SetBounds(Left, Top, Right - Left - 1, Bottom - Top - 1);
end;

procedure TRichMemoCellEditor.MsgSetValue(var Msg: TGridMessage);
begin
  Text := Msg.Value;
end;

procedure TRichMemoCellEditor.MsgGetValue(var Msg: TGridMessage);
begin
  Msg.Value := Text;
end;

end.
