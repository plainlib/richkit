unit RichMemoCellEditor;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  StdCtrls,
  SysUtils,
  Types,
  Controls,
  LMessages,
  Grids,
  RichMemo;

type
  TRichMemoCellEditor = class(TRichMemo)
  private
    FGrid: TCustomGrid;
    FCol: integer;
    FRow: integer;
    FPendingValue: string;
    FPendingValueSet: boolean;
  protected
    procedure MsgSetGrid(var Msg: TGridMessage); message GM_SETGRID;
    procedure MsgSetPos(var Msg: TGridMessage); message GM_SETPOS;
    procedure MsgSetBounds(var Msg: TGridMessage); message GM_SETBOUNDS;
    procedure MsgSetValue(var Msg: TGridMessage); message GM_SETVALUE;
    procedure MsgGetValue(var Msg: TGridMessage); message GM_GETVALUE;
    procedure DoEnter; override;
    procedure InitializeEditor; virtual;
    procedure ApplyPendingValue;
    procedure CMShowingChanged(var Msg: TLMessage); message CM_SHOWINGCHANGED;
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  LCLIntf,
  LCLType;

const
  // Not declared in all LCL builds, define it locally
  EM_CHARFROMPOS = $00D7;

constructor TRichMemoCellEditor.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // Apply default settings right after the component is created
  FPendingValue := '';
  FPendingValueSet := False;
  InitializeEditor;
end;

procedure TRichMemoCellEditor.InitializeEditor;
begin
  // Set up default appearance and behaviour of the cell editor here
  Visible := False;
  HideSelection := False;
  BorderStyle := bsNone;
  TabStop := False;
  WantTabs := True;
  WantReturns := True;
  BiDiMode := bdLeftToRight;
end;

procedure TRichMemoCellEditor.MsgSetGrid(var Msg: TGridMessage);
begin
  FGrid := Msg.Grid;
end;

procedure TRichMemoCellEditor.MsgSetPos(var Msg: TGridMessage);
begin
  FCol := Msg.Col;
  FRow := Msg.Row;
end;

procedure TRichMemoCellEditor.MsgSetBounds(var Msg: TGridMessage);
begin
  with Msg.CellRect do
    SetBounds(Left + 2, Top + 3, Right - Left - 3, Bottom - Top - 1);
end;

procedure TRichMemoCellEditor.MsgSetValue(var Msg: TGridMessage);
begin
  // Store the value and try to apply it right away
  FPendingValue := Msg.Value;
  FPendingValueSet := True;
  ApplyPendingValue;
end;

procedure TRichMemoCellEditor.MsgGetValue(var Msg: TGridMessage);
begin
  Msg.Value := Text;
end;

procedure TRichMemoCellEditor.ApplyPendingValue;
begin
  if not FPendingValueSet then
    Exit;
  // Force the window handle to exist before touching the text
  HandleNeeded;
  Lines.BeginUpdate;
  try
    Clear;
    SelStart := 0;
    SelLength := 0;
    SelText := FPendingValue;
    SelStart := 0;
    SelLength := 0;
  finally
    Lines.EndUpdate;
  end;
  FPendingValueSet := False;
end;

procedure TRichMemoCellEditor.CMShowingChanged(var Msg: TLMessage);
begin
  inherited;
  // Reapply the value when the editor becomes visible again
  if Showing then
    ApplyPendingValue;
end;

procedure TRichMemoCellEditor.DoEnter;
var
  P: TPoint;
  Param: LPARAM;
  Res: LResult;
  CharIdx: integer;
begin
  inherited DoEnter;
  // Place the caret at the click position if the mouse is over the editor
  P := ScreenToClient(Mouse.CursorPos);
  if PtInRect(ClientRect, P) then
  begin
    {$HINTS OFF}
    Param := LPARAM(PtrInt(@P));
    {$HINTS ON}
    Res := SendMessage(Handle, EM_CHARFROMPOS, 0, Param);
    CharIdx := Res and $FFFF;
    if CharIdx >= 0 then
    begin
      SelStart := CharIdx;
      SelLength := 0;
    end;
  end
  else
    SelStart := Length(Text);
end;

end.
