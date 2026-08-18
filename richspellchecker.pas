unit RichSpellChecker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Menus, Graphics, Types, RichMemo;

type
  TSpellError = record
    Offset: integer;
    Length: integer;
    Message: string;
    Replacements: TStringList;
  end;
  PSpellError = ^TSpellError;

  TRichSpellChecker = class
  private
    FRichMemo: TRichMemo;
    FMenu: TPopupMenu;
    FErrors: TList;
    FCurrentError: PSpellError;
    FOnSpellCheckNeeded: TNotifyEvent;
    FApplyImmediately: boolean;
    FContextCaretPos: integer; // caret position when context menu was invoked
    function GetErrorAtTextPos(ATextPos: integer): PSpellError;
    procedure ApplyUnderlineToError(AError: PSpellError);
    procedure ClearUnderlines;
    procedure ReplacementClick(Sender: TObject);
    function GetCharIndexAtPos(X, Y: integer): integer;
    // Temporarily suspend Undo recording to avoid formatting operations being undoable
    procedure SuspendUndo;  // temporarily suspend Undo recording
    procedure ResumeUndo;   // resume Undo recording
  public
    constructor Create(ARichMemo: TRichMemo);
    destructor Destroy; override;
    procedure Clear;
    procedure BeginUpdate;
    procedure EndUpdate;
    procedure AddError(AOffset, ALength: integer; const AMessage: string; const AReplacements: array of string);
    procedure ApplyUnderlines;
    procedure ShowContextMenu(X, Y: integer);
    procedure ReplaceError(AError: PSpellError; const ANewText: string; NewCaretPos: integer = -1);
    // Remove a single error from the list and clear its underline
    procedure RemoveError(AError: PSpellError; ANewLength: integer);
    property OnSpellCheckNeeded: TNotifyEvent read FOnSpellCheckNeeded write FOnSpellCheckNeeded;
  end;

implementation

{$IFDEF WINDOWS}
uses
  Windows, LCLType, ComObj, ActiveX, Variants;

const
  EM_EXSETSEL = WM_USER + 55;
  EM_SETCHARFORMAT = WM_USER + 68;
  EM_CHARFROMPOS = $00D7;
  EM_GETOLEINTERFACE = WM_USER + 60; // added

  SCF_SELECTION = $0001;

  CFM_UNDERLINE = $00000004;
  CFM_UNDERLINETYPE = $00800000;
  CFM_UNDERLINECOLOR = $10000000;

  CFE_UNDERLINE = $00000004;
  CFU_UNDERLINENONE = 0;
  CFU_UNDERLINEWAVE = 8;
  UNDERLINE_COLOR_RED = 6;

  EM_GETSCROLLPOS = WM_USER + 221;
  EM_SETSCROLLPOS = WM_USER + 222;

  tomSuspend = -9999995; // tomSuspend constant
  tomResume  = -9999994; // tomResume constant

type
  CHARRANGE = record
    cpMin: Longint;
    cpMax: Longint;
  end;

  CHARFORMAT2W = record
    cbSize: UINT;
    dwMask: DWORD;
    dwEffects: DWORD;
    yHeight: Longint;
    yOffset: Longint;
    crTextColor: COLORREF;
    bCharSet: Byte;
    bPitchAndFamily: Byte;
    szFaceName: array[0..31] of WideChar;
    wWeight: Word;
    sSpacing: Smallint;
    crBackColor: COLORREF;
    lcid: LCID;
    dwReserved: DWORD;
    sStyle: Smallint;
    wKerning: Word;
    bUnderlineType: Byte;
    bAnimation: Byte;
    bRevAuthor: Byte;
    bUnderlineColor: Byte;
  end;
{$ENDIF}

constructor TRichSpellChecker.Create(ARichMemo: TRichMemo);
begin
  inherited Create;
  FRichMemo := ARichMemo;
  FMenu := TPopupMenu.Create(nil);
  FErrors := TList.Create;
  FCurrentError := nil;
  FApplyImmediately := True;
  FContextCaretPos := -1;
end;

destructor TRichSpellChecker.Destroy;
begin
  Clear;
  FreeAndNil(FMenu);
  FreeAndNil(FErrors);
  inherited Destroy;
end;

procedure TRichSpellChecker.Clear;
var
  i: integer;
  p: PSpellError;
begin
  for i := FErrors.Count - 1 downto 0 do
  begin
    p := PSpellError(FErrors[i]);
    if Assigned(p) then
    begin
      if Assigned(p^.Replacements) then
        p^.Replacements.Free;
      Dispose(p);
    end;
    FErrors.Delete(i);
  end;
  FCurrentError := nil;
  ClearUnderlines;
end;

procedure TRichSpellChecker.BeginUpdate;
begin
  FApplyImmediately := False;
end;

procedure TRichSpellChecker.EndUpdate;
begin
  FApplyImmediately := True;
  ApplyUnderlines;
end;

procedure TRichSpellChecker.SuspendUndo;
{$IFDEF WINDOWS}
var
  RichEditOle: IUnknown;
  Doc: IDispatch;
  DispID: TDispID;
  Params: array[0..0] of OleVariant;
  DispParams: TDispParams;
  NameWide: WideString;
  NamePtr: PWideChar;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  RichEditOle := nil;
  DispParams:=Default(TDispParams);
  {$HINTS OFF}
  if SendMessage(FRichMemo.Handle, EM_GETOLEINTERFACE, 0, LPARAM(@RichEditOle)) = 0 then Exit;
  {$HINTS ON}
  if not Assigned(RichEditOle) then Exit;
  if Failed(RichEditOle.QueryInterface(IDispatch, Doc)) then Exit;

  NameWide := 'Undo';
  NamePtr := PWideChar(NameWide);
  if Failed(Doc.GetIDsOfNames(GUID_NULL, @NamePtr, 1, LOCALE_SYSTEM_DEFAULT, @DispID)) then
    Exit;

  {$NOTES OFF}
  Params[0] := tomSuspend;
  {$NOTES ON}
  FillChar(DispParams, SizeOf(DispParams), 0);
  DispParams.rgvarg := @Params[0];
  DispParams.cArgs := 1;
  Doc.Invoke(DispID, GUID_NULL, LOCALE_SYSTEM_DEFAULT, DISPATCH_METHOD,
    DispParams, nil, nil, nil);
  {$ENDIF}
end;

procedure TRichSpellChecker.ResumeUndo;
{$IFDEF WINDOWS}
var
  RichEditOle: IUnknown;
  Doc: IDispatch;
  DispID: TDispID;
  Params: array[0..0] of OleVariant;
  DispParams: TDispParams;
  NameWide: WideString;
  NamePtr: PWideChar;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  RichEditOle := nil;
  DispParams:=Default(TDispParams);
  {$HINTS OFF}
  if SendMessage(FRichMemo.Handle, EM_GETOLEINTERFACE, 0, LPARAM(@RichEditOle)) = 0 then Exit;
  {$HINTS ON}
  if not Assigned(RichEditOle) then Exit;
  if Failed(RichEditOle.QueryInterface(IDispatch, Doc)) then Exit;

  NameWide := 'Undo';
  NamePtr := PWideChar(NameWide);
  if Failed(Doc.GetIDsOfNames(GUID_NULL, @NamePtr, 1, LOCALE_SYSTEM_DEFAULT, @DispID)) then
    Exit;

  {$NOTES OFF}
  Params[0] := tomResume;
  {$NOTES ON}
  FillChar(DispParams, SizeOf(DispParams), 0);
  DispParams.rgvarg := @Params[0];
  DispParams.cArgs := 1;
  Doc.Invoke(DispID, GUID_NULL, LOCALE_SYSTEM_DEFAULT, DISPATCH_METHOD,
    DispParams, nil, nil, nil);
  {$ENDIF}
end;

procedure TRichSpellChecker.ClearUnderlines;
var
  OldSelStart, OldSelLength: integer;
  {$IFDEF WINDOWS}
  cf: CHARFORMAT2W;
  cr: CHARRANGE;
  scrollPos: TPoint;
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  if not Assigned(FRichMemo) then
    Exit;

  // Save caret position
  OldSelStart := FRichMemo.SelStart;
  OldSelLength := FRichMemo.SelLength;

  // Save scroll position
  {$HINTS OFF}
  SendMessage(FRichMemo.Handle, EM_GETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
  {$HINTS ON}

  // Suspend Undo so this formatting change does not appear in history
  SuspendUndo;
  try
    // Block repainting
    SendMessage(FRichMemo.Handle, WM_SETREDRAW, 0, 0);
    try
      cr.cpMin := 0;
      cr.cpMax := Length(FRichMemo.Text);
      {$HINTS OFF}
      SendMessage(FRichMemo.Handle, EM_EXSETSEL, 0, LPARAM(PtrInt(@cr)));
      {$HINTS ON}

      cf := Default(CHARFORMAT2W);
      cf.cbSize := SizeOf(cf);
      cf.dwMask := CFM_UNDERLINE or CFM_UNDERLINETYPE or CFM_UNDERLINECOLOR;
      cf.dwEffects := 0;
      cf.bUnderlineType := CFU_UNDERLINENONE;
      cf.bUnderlineColor := 0;

      {$HINTS OFF}
      SendMessage(FRichMemo.Handle, EM_SETCHARFORMAT, SCF_SELECTION, LPARAM(PtrInt(@cf)));
      {$HINTS ON}
    finally
      // Restore caret position
      FRichMemo.SelStart := OldSelStart;
      FRichMemo.SelLength := OldSelLength;
      // Restore scroll position
      {$HINTS OFF}
      SendMessage(FRichMemo.Handle, EM_SETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
      {$HINTS ON}
      SendMessage(FRichMemo.Handle, WM_SETREDRAW, 1, 0);
      FRichMemo.Invalidate;
    end;
  finally
    ResumeUndo;
  end;
  {$ELSE}
  if not Assigned(FRichMemo) then
    Exit;
  if Length(FRichMemo.Text) = 0 then
    Exit;

  // Save caret position
  OldSelStart := FRichMemo.SelStart;
  OldSelLength := FRichMemo.SelLength;

  FRichMemo.SelStart := 0;
  FRichMemo.SelLength := Length(FRichMemo.Text);
  FRichMemo.SelAttributes.Style := FRichMemo.SelAttributes.Style - [fsUnderline];
  // Restore caret position
  FRichMemo.SelStart := OldSelStart;
  FRichMemo.SelLength := OldSelLength;
  {$ENDIF}
end;

procedure TRichSpellChecker.AddError(AOffset, ALength: integer; const AMessage: string; const AReplacements: array of string);
var
  err: PSpellError;
  i: integer;
begin
  New(err);
  err^.Offset := AOffset;
  err^.Length := ALength;
  err^.Message := AMessage;
  err^.Replacements := TStringList.Create;
  for i := Low(AReplacements) to High(AReplacements) do
    err^.Replacements.Add(AReplacements[i]);

  FErrors.Add(err);
  if FApplyImmediately then
    ApplyUnderlineToError(err);
end;

procedure TRichSpellChecker.ApplyUnderlineToError(AError: PSpellError);
{$IFDEF WINDOWS}
var
  cf: CHARFORMAT2W;
  cr: CHARRANGE;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  if not Assigned(FRichMemo) or (AError = nil) then
    Exit;

  // Suspend Undo for this formatting operation
  SuspendUndo;
  try
    cr.cpMin := AError^.Offset;
    cr.cpMax := AError^.Offset + AError^.Length;
    {$HINTS OFF}
    SendMessage(FRichMemo.Handle, EM_EXSETSEL, 0, LPARAM(PtrInt(@cr)));
    {$HINTS ON}

    cf := Default(CHARFORMAT2W);
    cf.cbSize := SizeOf(cf);
    cf.dwMask := CFM_UNDERLINE or CFM_UNDERLINETYPE or CFM_UNDERLINECOLOR;
    cf.dwEffects := CFE_UNDERLINE;
    cf.bUnderlineType := CFU_UNDERLINEWAVE;
    cf.bUnderlineColor := UNDERLINE_COLOR_RED;

    {$HINTS OFF}
    SendMessage(FRichMemo.Handle, EM_SETCHARFORMAT, SCF_SELECTION, LPARAM(PtrInt(@cf)));
    {$HINTS ON}

    FRichMemo.SelLength := 0;
  finally
    ResumeUndo;
  end;
  {$ELSE}
  if not Assigned(FRichMemo) or (AError = nil) then
    Exit;

  FRichMemo.SelStart := AError^.Offset;
  FRichMemo.SelLength := AError^.Length;
  FRichMemo.SelAttributes.Style := FRichMemo.SelAttributes.Style + [fsUnderline];
  FRichMemo.SelLength := 0;
  {$ENDIF}
end;

procedure TRichSpellChecker.ApplyUnderlines;
{$IFDEF WINDOWS}
var
  i: integer;
  scrollPos: TPoint;
  OldSelStart, OldSelLength: integer;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  if not Assigned(FRichMemo) then
    Exit;

  // Save caret position
  OldSelStart := FRichMemo.SelStart;
  OldSelLength := FRichMemo.SelLength;

  // Save scroll position
  {$HINTS OFF}
  SendMessage(FRichMemo.Handle, EM_GETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
  {$HINTS ON}

  // Suspend Undo for the entire batch of formatting
  SuspendUndo;
  try
    // Block repainting while applying all underlines
    SendMessage(FRichMemo.Handle, WM_SETREDRAW, 0, 0);
    try
      for i := 0 to FErrors.Count - 1 do
        ApplyUnderlineToError(PSpellError(FErrors[i]));
    finally
      // Restore caret position
      FRichMemo.SelStart := OldSelStart;
      FRichMemo.SelLength := OldSelLength;
      // Restore scroll position
      {$HINTS OFF}
      SendMessage(FRichMemo.Handle, EM_SETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
      {$HINTS ON}
      SendMessage(FRichMemo.Handle, WM_SETREDRAW, 1, 0);
      FRichMemo.Invalidate;
    end;
  finally
    ResumeUndo;
  end;
  {$ENDIF}
end;

function TRichSpellChecker.GetErrorAtTextPos(ATextPos: integer): PSpellError;
var
  i: integer;
  err: PSpellError;
begin
  Result := nil;
  for i := 0 to FErrors.Count - 1 do
  begin
    err := PSpellError(FErrors[i]);
    if (ATextPos >= err^.Offset) and (ATextPos < err^.Offset + err^.Length) then
    begin
      Result := err;
      Exit;
    end;
  end;
end;

function TRichSpellChecker.GetCharIndexAtPos(X, Y: integer): integer;
var
  {$IFDEF WINDOWS}
  Pt: TPoint;
  {$ELSE}
  ClientX: integer;
  CharWidth: integer;
  ClientRect: TRect;
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  Pt.X := X;
  Pt.Y := Y;

  Result := SendMessage(
    FRichMemo.Handle,
    EM_CHARFROMPOS,
    0,
    {$HINTS OFF}
    LPARAM(PtrInt(@Pt))
    {$HINTS ON}
  );

  if Result < 0 then
    Result := -1;
  {$ELSE}
  if not Assigned(FRichMemo) then
    Exit(-1);

  ClientX := X;
  ClientRect := FRichMemo.ClientRect;

  if (ClientX < ClientRect.Left) or (ClientX > ClientRect.Right) then
    Exit(-1);

  CharWidth := Round(FRichMemo.Font.Size * 0.6);
  if CharWidth = 0 then
    CharWidth := 8;

  Result := (ClientX - ClientRect.Left) div CharWidth;

  if Result > Length(FRichMemo.Text) then
    Result := -1;
  {$ENDIF}
end;

procedure TRichSpellChecker.ShowContextMenu(X, Y: integer);
var
  CharIndex: integer;
  Error: PSpellError;
  Item: TMenuItem;
  i: integer;
  ScreenPoint: TPoint;
begin
  if not Assigned(FRichMemo) then
    Exit;

  CharIndex := GetCharIndexAtPos(X, Y);
  if CharIndex < 0 then
    Exit;

  Error := GetErrorAtTextPos(CharIndex);
  if Error = nil then
    Exit;

  FCurrentError := Error;
  // Save caret position for later restore after replacement
  FContextCaretPos := FRichMemo.SelStart;

  // Clear previous menu items
  FMenu.Items.Clear;

  // Add new replacement items
  for i := 0 to Error^.Replacements.Count - 1 do
  begin
    Item := TMenuItem.Create(FMenu);
    Item.Caption := Error^.Replacements[i];
    Item.OnClick := @ReplacementClick;
    FMenu.Items.Add(Item);
  end;

  if FMenu.Items.Count > 0 then
  begin
    // Convert client coordinates to screen coordinates for Popup
    ScreenPoint := FRichMemo.ClientToScreen(Types.Point(X, Y));
    FMenu.Popup(ScreenPoint.X, ScreenPoint.Y);
  end;
end;

procedure TRichSpellChecker.ReplacementClick(Sender: TObject);
var
  Item: TMenuItem;
  Replacement: string;
  NewCaretPos: integer;
  RelPos: integer;
  OldError: PSpellError;
  NewLength: integer;
begin
  if FCurrentError = nil then
    Exit;

  Item := Sender as TMenuItem;
  Replacement := Item.Caption;
  OldError := FCurrentError;
  NewLength := Length(Replacement);

  // Calculate new caret position based on saved context position
  NewCaretPos := -1;
  if (FContextCaretPos >= OldError^.Offset) and (FContextCaretPos <= OldError^.Offset + OldError^.Length) then
  begin
    RelPos := FContextCaretPos - OldError^.Offset;
    if RelPos > NewLength then
      RelPos := NewLength;
    NewCaretPos := OldError^.Offset + RelPos;
  end;

  // Replace the error text (normal undoable operation)
  ReplaceError(OldError, Replacement, NewCaretPos);

  // Remove only this error and its underline, without full clear
  RemoveError(OldError, NewLength);

  // Ensure no selection remains
  FRichMemo.SelLength := 0;

  // Reset context caret position
  FContextCaretPos := -1;
  FCurrentError := nil;

  if Assigned(FOnSpellCheckNeeded) then
    FOnSpellCheckNeeded(Self);
end;

procedure TRichSpellChecker.ReplaceError(AError: PSpellError; const ANewText: string; NewCaretPos: integer);
begin
  if not Assigned(FRichMemo) or (AError = nil) then
    Exit;

  FRichMemo.SelStart := AError^.Offset;
  FRichMemo.SelLength := AError^.Length;
  FRichMemo.SelText := ANewText; // this will be recorded in Undo

  // Set caret to desired position if specified
  if NewCaretPos >= 0 then
  begin
    FRichMemo.SelStart := NewCaretPos;
    FRichMemo.SelLength := 0;
  end
  else
    FRichMemo.SelLength := 0; // just remove selection
end;

procedure TRichSpellChecker.RemoveError(AError: PSpellError; ANewLength: integer);
var
  OldSelStart, OldSelLength: integer;
  scrollPos: TPoint;
  {$IFDEF WINDOWS}
  cf: CHARFORMAT2W;
  cr: CHARRANGE;
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  if not Assigned(FRichMemo) or (AError = nil) then
    Exit;

  // Save caret and scroll position
  OldSelStart := FRichMemo.SelStart;
  OldSelLength := FRichMemo.SelLength;
  {$HINTS OFF}
  SendMessage(FRichMemo.Handle, EM_GETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
  {$HINTS ON}

  // Suspend Undo for formatting change
  SuspendUndo;
  try
    // Select the new text range (old offset, new length)
    cr.cpMin := AError^.Offset;
    cr.cpMax := AError^.Offset + ANewLength;
    {$HINTS OFF}
    SendMessage(FRichMemo.Handle, EM_EXSETSEL, 0, LPARAM(PtrInt(@cr)));
    {$HINTS ON}

    // Clear underline only for the selected range
    cf := Default(CHARFORMAT2W);
    cf.cbSize := SizeOf(cf);
    cf.dwMask := CFM_UNDERLINE or CFM_UNDERLINETYPE or CFM_UNDERLINECOLOR;
    cf.dwEffects := 0;
    cf.bUnderlineType := CFU_UNDERLINENONE;
    cf.bUnderlineColor := 0;
    {$HINTS OFF}
    SendMessage(FRichMemo.Handle, EM_SETCHARFORMAT, SCF_SELECTION, LPARAM(PtrInt(@cf)));
    {$HINTS ON}

    // Restore caret and scroll
    FRichMemo.SelStart := OldSelStart;
    FRichMemo.SelLength := OldSelLength;
    {$HINTS OFF}
    SendMessage(FRichMemo.Handle, EM_SETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
    {$HINTS ON}
  finally
    ResumeUndo;
  end;

  // Remove error from list
  FErrors.Remove(AError);
  if Assigned(AError^.Replacements) then
    AError^.Replacements.Free;
  Dispose(AError);
  {$ENDIF}
end;

end.
