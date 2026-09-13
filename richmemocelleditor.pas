unit RichMemoCellEditor;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  StdCtrls,
  SysUtils,
  Types,
  Controls,
  ExtCtrls,
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
    FHost: TPanel;
    FInternalParent: boolean;
    FCellRect: TRect;
    FCellRectSet: boolean;
    procedure EnsureHost;
    procedure ApplyCellBounds;
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
    procedure SetParent(AParent: TWinControl); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetBounds(ALeft, ATop, AWidth, AHeight: integer); override;
    procedure SetVisible(Value: boolean); override;
  end;

implementation

uses
  LCLIntf,
  LCLType;

const
  // The GTK widgetset imposes a minimum height on TRichMemo, so the memo
  // is always at least this tall and gets clipped by the host panel
  MinMemoHeight = 40;

{$IFDEF WINDOWS}
const
  // Not declared in all LCL builds, define it locally
  EM_CHARFROMPOS = $00D7;
{$ENDIF}

constructor TRichMemoCellEditor.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // Apply default settings right after the component is created
  FPendingValue := '';
  FPendingValueSet := False;
  FHost := nil;
  FInternalParent := False;
  FCellRect := Rect(0, 0, 0, 0);
  FCellRectSet := False;
  InitializeEditor;
end;

procedure TRichMemoCellEditor.EnsureHost;
begin
  if FHost = nil then
  begin
    FHost := TPanel.Create(Self);
    FHost.Align := alNone;
    FHost.Anchors := [];
    FHost.AutoSize := False;
    FHost.BevelOuter := bvNone;
    FHost.BorderStyle := bsNone;
    FHost.Caption := '';
    FHost.TabStop := False;
    FHost.Visible := False;
  end;
end;

procedure TRichMemoCellEditor.ApplyCellBounds;
var
  MemoWidth: integer;
  MemoHeight: integer;
begin
  if not FCellRectSet or (FHost = nil) or (FHost.Parent = nil) then
    Exit;

  FHost.SetBounds(
    FCellRect.Left + 2,
    FCellRect.Top + 3,
    FCellRect.Right - FCellRect.Left - 3,
    FCellRect.Bottom - FCellRect.Top - 1
    );

  MemoWidth := FCellRect.Right - FCellRect.Left - 3;
  MemoHeight := FCellRect.Bottom - FCellRect.Top - 1;

  if MemoHeight < MinMemoHeight then
    MemoHeight := MinMemoHeight;

  inherited SetBounds(0, 0, MemoWidth, MemoHeight);
end;

procedure TRichMemoCellEditor.SetParent(AParent: TWinControl);
begin
  if FInternalParent then
  begin
    inherited SetParent(AParent);
    Exit;
  end;

  if AParent = nil then
  begin
    if FHost <> nil then
      FHost.Parent := nil;

    inherited SetParent(nil);
    Exit;
  end;

  EnsureHost;
  FHost.Parent := AParent;

  FInternalParent := True;
  try
    inherited SetParent(FHost);
  finally
    FInternalParent := False;
  end;

  ApplyCellBounds;
  ApplyPendingValue;
end;

procedure TRichMemoCellEditor.SetBounds(ALeft, ATop, AWidth, AHeight: integer);
var
  MemoHeight: integer;
begin
  if (FHost <> nil) and (Parent = FHost) then
  begin
    MemoHeight := AHeight;

    if MemoHeight < MinMemoHeight then
      MemoHeight := MinMemoHeight;

    // Do not change the host position here.
    // LCL can call SetBounds during parent or widget initialization.
    inherited SetBounds(0, 0, AWidth, MemoHeight);
  end
  else
    inherited SetBounds(ALeft, ATop, AWidth, AHeight);
end;

procedure TRichMemoCellEditor.SetVisible(Value: boolean);
begin
  if (FHost <> nil) and (Parent = FHost) then
    FHost.Visible := Value;

  inherited SetVisible(Value);
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
  FCellRect := Msg.CellRect;
  FCellRectSet := True;
  ApplyCellBounds;
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

  // A handle cannot be created without a parent; retry later via the
  // CMShowingChanged, DoEnter or SetParent code paths
  if Parent = nil then
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
  GridPoint: TPoint;
  P: TPoint;
  CharIdx: integer;
  {$IFDEF WINDOWS}
  Param: LPARAM;
  Res: LResult;
  {$ENDIF}
begin
  inherited DoEnter;

  // Retry in case the pending value could not be applied earlier
  ApplyPendingValue;

  if not HandleAllocated then
    Exit;

  if not FCellRectSet or (FGrid = nil) then
  begin
    SelStart := Length(Text);
    Exit;
  end;

  // Get the mouse position in grid coordinates.
  GridPoint := FGrid.ScreenToClient(Mouse.CursorPos);

  // Convert the mouse position from grid coordinates to memo coordinates.
  P.X := GridPoint.X - FCellRect.Left - 2;
  P.Y := GridPoint.Y - FCellRect.Top - 3;

  if PtInRect(ClientRect, P) then
  begin
    {$IFDEF WINDOWS}
    {$HINTS OFF}
    Param := LPARAM(PtrInt(@P));
    {$HINTS ON}

    Res := SendMessage(Handle, EM_CHARFROMPOS, 0, Param);
    CharIdx := Res AND $FFFF;
    {$ELSE}
    CharIdx := CharAtPos(P.X, P.Y);
    {$ENDIF}

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
