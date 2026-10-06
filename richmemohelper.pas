//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit RichMemoHelper;

{$mode objfpc}{$H+}

interface

uses
  Controls,
  Classes,
  Graphics,
  Types,
  Math,
  SysUtils,
  StrUtils,
  Clipbrd,
  ExtCtrls,
  {$IFDEF WINDOWS}
  Windows,
  RichEdit,
  ActiveX,
  {$ENDIF}
  LCLType,
  LCLIntf,
  LazUtf8,
  RichMemo,
  RichMemoHelpers;

type
  TRichMemoHelper = class helper(TRichEditForMemo) for TRichMemo
  public
    procedure EnableUndo;
    procedure DisableUndo;
    function IsUndoEnabled: boolean;
    procedure BeginUndoBatch;
    procedure EndUndoBatch;
    procedure PushUndoSnapshot;
    procedure UndoEx;
    procedure RedoEx;
    function CanUndo: boolean;
    function CanRedo: boolean;
    procedure ClearUndoHistory;

    // Paste HTML content from clipboard as RTF at cursor position
    function PasteFromClipboardEx(AUseHtmlFormat: boolean = True): boolean;

    // Copy selected content to clipboard in plain text, RTF and HTML formats
    function CopyToClipboardEx: boolean;

    // Cut selected content to clipboard in plain text, RTF and HTML formats
    function CutToClipboardEx: boolean;

    // Cut selected content to clipboard without trailing line breaks
    procedure CutToClipboardNoTrailingLineBreak;

    // Inserts clipboard text, normalizing all line endings to LineEnding.
    procedure PasteWithLineEnding;

    // Detects whether the document contains rich text formatting
    function HasRichFormatting: boolean;

    // Inserts the given RTF fragment at the current cursor position.
    // The fragment should be raw RTF content (e.g., '{\b bold}') without
    // the outer document braces and header.
    procedure InsertRtfAtCursor(const ARtf: string);

    // Set text bidi mode
    procedure ApplyBidiMode;

    // Get full text height
    function GetTextHeight(AText: string): integer;

    // Resets line spacing and paragraph spacing to remove extra CJK gaps in RichMemo
    procedure ResetParaSpacing;

    // Returns the free space below the text in the memo's client area.
    function GetBottomSpace: integer;

    // Safely saves memo text to file, silently ignoring any errors.
    procedure SaveToFileSafe(AFileName: string);

    // Selects the token at APos, treating AExtraChars as part of word characters.
    procedure MemoTokenAtPos(APos: integer; const AExtraChars: unicodestring);

    // Temporarily suspend Undo recording to avoid formatting operations being undoable
    // Suspend Undo recording
    procedure SuspendUndo;

    // Temporarily suspend Undo recording to avoid formatting operations being undoable
    // Resume Undo recording
    procedure ResumeUndo;

    // Sets the left indent (in pixels) for all paragraphs in the document.
    procedure SetLeftIndent(AIndentPixels: integer = 3);

    // Disable built-in OLE drag-and-drop (text dragging within RichMemo and receiving from outside)
    procedure DisableBuiltInDragDrop;

    // Disable Composited mode while scrolling Memo
    procedure EnableScrollbarFix(AParentPanel: TWinControl);

    // Assigns text while maintaining zoom factor
    procedure SetTextSafe(const AText: string);

    // Clears memo content, creating an undo point so the operation can be undone
    procedure ClearWithUndo;

    // Apply memo settings and related visual properties.
    procedure UpdateState(AIndentPixels: integer = 3; AResetParaSpacing: boolean = False);
  end;

implementation

uses
  Forms,
  HtmlToRtf,
  {$IFDEF WINDOWS}
  RtfToHtml,
  clipboardhelper,
  {$ENDIF}
  {$IFDEF LCLGTK2}
  gtk2,
  glib2,
  {$ENDIF}
  ClipToHtml,
  stringhelper,
  controlshelper;

  {$IFDEF WINDOWS}

const
  SCROLLBAR_FIX_TIMER_ID = 1;
  SCROLLBAR_FIX_INTERVAL = 30;
  SCROLLBAR_DRAG_PROP = 'ScrollFixDragging';
  tomSuspend = -9999995;
  tomResume = -9999994;

procedure RichMemoScrollbarFixTimer(
  Wnd: HWND;
  uMsg: UINT;
  idEvent: UINT_PTR;
  dwTime: DWORD); stdcall;
var
  ParentPanel: TWinControl;
  Rect: TRect;
  CursorPos: TPoint;
  ScrollbarSize: Integer;
  OverScrollbar: Boolean;
  Dragging: Boolean;
  LeftDown: Boolean;
  NeedComposited: Boolean;
  CurrentComposited: Boolean;
  ExStyle: LONG_PTR;
begin
  ParentPanel := TWinControl(Pointer(GetProp(
    Wnd, 'ScrollFixParentPanel')));

  if not Assigned(ParentPanel) then Exit;
  if not ParentPanel.HandleAllocated then Exit;

  CursorPos := Default(TPoint);
  Rect := Default(TRect);

  GetCursorPos(CursorPos);
  GetWindowRect(Wnd, Rect);

  OverScrollbar := False;

  // Check if cursor is over vertical scrollbar
  ScrollbarSize := GetSystemMetrics(SM_CXVSCROLL);

  if (GetWindowLongPtr(Wnd, GWL_STYLE) and WS_VSCROLL) <> 0 then
    if (CursorPos.X >= Rect.Right - ScrollbarSize) and
       (CursorPos.X < Rect.Right) and
       (CursorPos.Y >= Rect.Top) and
       (CursorPos.Y < Rect.Bottom) then
      OverScrollbar := True;

  // Check if cursor is over horizontal scrollbar
  if not OverScrollbar then
  begin
    ScrollbarSize := GetSystemMetrics(SM_CYHSCROLL);

    if (GetWindowLongPtr(Wnd, GWL_STYLE) and WS_HSCROLL) <> 0 then
      if (CursorPos.Y >= Rect.Bottom - ScrollbarSize) and
         (CursorPos.Y < Rect.Bottom) and
         (CursorPos.X >= Rect.Left) and
         (CursorPos.X < Rect.Right) then
        OverScrollbar := True;
  end;

  // A scrollbar drag session starts only when the left button is pressed
  // while the cursor is over the scrollbar. Once started, the session
  // continues until the left button is released, even if the cursor
  // moves away from the scrollbar area. This keeps the scrollbar repainting
  // correctly for the whole drag, not only while the cursor stays on it
  Dragging := GetProp(Wnd, SCROLLBAR_DRAG_PROP) <> nil;
  LeftDown := (GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0;

  if LeftDown then
  begin
    if (not Dragging) and OverScrollbar then
    begin
      Dragging := True;
      SetProp(Wnd, SCROLLBAR_DRAG_PROP, Pointer(1));
    end;
  end
  else if Dragging then
  begin
    Dragging := False;
    RemoveProp(Wnd, SCROLLBAR_DRAG_PROP);
  end;

  // Keep compositing disabled for the whole scrollbar drag session
  NeedComposited := not Dragging;

  ExStyle := GetWindowLongPtr(ParentPanel.Handle, GWL_EXSTYLE);
  CurrentComposited := (ExStyle and WS_EX_COMPOSITED) <> 0;

  if CurrentComposited <> NeedComposited then
    ParentPanel.SetComposited(NeedComposited);
end;

  {$ENDIF}

type
  TSnapshotKind = (skNone, skText, skRtf);

  TRichMemoSnapshot = record
    Kind: TSnapshotKind;
    PrefixChars: integer;
    OldTailChars: integer;
    NewTailChars: integer;
    OldTail: string;
    NewTail: string;
    Rtf: string;
    SelStart: integer;
    SelLength: integer;
  end;

  TRichMemoSnapshotArray = array of TRichMemoSnapshot;

  TRichMemoBaseline = record
    Rtf: string;
    Text: string;
    SelStart: integer;
    SelLength: integer;
  end;

{$IFDEF LCLGTK2}

  var
    GCachedHandleValue: TLCLHandle = 0;
    GCachedView: PGtkTextView = nil;

function GetGtkTextViewFromMemo(AMemo: TCustomRichMemo): PGtkTextView;
var
  W: PGtkWidget;
  List: PGList;
  H: TLCLHandle;
begin
  Result := nil;
  if not AMemo.HandleAllocated then Exit;

  // Cache the underlying PGtkTextView per handle: gtk_container_get_children
  // allocates a GList on every call, and this helper is invoked on every
  // caret move and every formatting operation, so the allocation becomes
  // measurable on GTK.
  H := TLCLHandle(AMemo.Handle);
  if H = GCachedHandleValue then
    Exit(GCachedView);

  {$HINTS OFF}
  W := PGtkWidget(PtrUInt(H));
  {$HINTS ON}
  if not Assigned(W) then Exit;
  List := gtk_container_get_children(PGtkContainer(W));
  if not Assigned(List) then Exit;
  Result := PGtkTextView(List^.data);
  g_list_free(List);

  GCachedHandleValue := H;
  GCachedView := Result;
end;

procedure EmitGtkClipboardSignal(AMemo: TCustomRichMemo; const ASignalName: string);
var
  View: PGtkTextView;
begin
  View := GetGtkTextViewFromMemo(AMemo);
  if not Assigned(View) then Exit;
  g_signal_emit_by_name(View, PChar(ASignalName));
end;

procedure GetCaretGTK2(AMemo: TCustomRichMemo; out AStart, ALen: Integer);
var
  View: PGtkTextView;
  Buf: PGtkTextBuffer;
  ItStart: TGtkTextIter;
  ItEnd: TGtkTextIter;
  Mark: PGtkTextMark;
begin
  AStart := 0;
  ALen := 0;
  View := GetGtkTextViewFromMemo(AMemo);
  if not Assigned(View) then Exit;
  Buf := gtk_text_view_get_buffer(View);
  if not Assigned(Buf) then Exit;

  if gtk_text_buffer_get_selection_bounds(Buf, @ItStart, @ItEnd) then
  begin
    AStart := gtk_text_iter_get_offset(@ItStart);
    ALen := gtk_text_iter_get_offset(@ItEnd) - AStart;
    if ALen < 0 then
    begin
      AStart := AStart + ALen;
      ALen := -ALen;
    end;
  end
  else
  begin
    Mark := gtk_text_buffer_get_insert(Buf);
    if Assigned(Mark) then
    begin
      gtk_text_buffer_get_iter_at_mark(Buf, @ItStart, Mark);
      AStart := gtk_text_iter_get_offset(@ItStart);
    end;
  end;
end;

procedure ApplyCaretGTK2(AMemo: TCustomRichMemo; APos, ALen: Integer);
var
  View: PGtkTextView;
  Buf: PGtkTextBuffer;
  ItStart: TGtkTextIter;
  ItEnd: TGtkTextIter;
  Mark: PGtkTextMark;
begin
  View := GetGtkTextViewFromMemo(AMemo);
  if not Assigned(View) then Exit;
  Buf := gtk_text_view_get_buffer(View);
  if not Assigned(Buf) then Exit;

  gtk_text_buffer_get_iter_at_offset(Buf, @ItStart, APos);
  if ALen > 0 then
  begin
    gtk_text_buffer_get_iter_at_offset(Buf, @ItEnd, APos + ALen);
    gtk_text_buffer_select_range(Buf, @ItStart, @ItEnd);
  end
  else
    gtk_text_buffer_place_cursor(Buf, @ItStart);

  Mark := gtk_text_buffer_get_insert(Buf);
  if Assigned(Mark) then
    gtk_text_view_scroll_to_mark(View, Mark, 0.0, True, 0.0, 0.5);
end;

{$ENDIF}

procedure GetCaretState(AMemo: TRichMemo; out AStart, ALen: integer);
begin
  {$IFDEF LCLGTK2}
  GetCaretGTK2(AMemo, AStart, ALen);
  {$ELSE}
  AStart := AMemo.SelStart;
  ALen := AMemo.SelLength;
  {$ENDIF}
end;

procedure SetCaretState(AMemo: TRichMemo; AStart, ALen: integer);
begin
  {$IFDEF LCLGTK2}
  ApplyCaretGTK2(AMemo, AStart, ALen);
  {$ELSE}
  AMemo.SelStart := AStart;
  AMemo.SelLength := ALen;
  {$ENDIF}
end;

procedure ComputeDiff(const AOldText, ANewText: string; out APrefixChars, AOldTailChars, ANewTailChars: integer;
  out AOldTail, ANewTail: string);
var
  OldUC, NewUC: unicodestring;
  P, S, MaxS, OldLen, NewLen: integer;
begin
  OldUC := UTF8Decode(AOldText);
  NewUC := UTF8Decode(ANewText);
  OldLen := Length(OldUC);
  NewLen := Length(NewUC);

  P := 0;
  while (P < OldLen) and (P < NewLen) and (OldUC[P + 1] = NewUC[P + 1]) do
    Inc(P);

  MaxS := Min(OldLen - P, NewLen - P);
  S := 0;
  while (S < MaxS) and (OldUC[OldLen - S] = NewUC[NewLen - S]) do
    Inc(S);

  APrefixChars := P;
  AOldTailChars := OldLen - P - S;
  ANewTailChars := NewLen - P - S;
  AOldTail := UTF8Encode(Copy(OldUC, P + 1, AOldTailChars));
  ANewTail := UTF8Encode(Copy(NewUC, P + 1, ANewTailChars));
end;

const
  MaxUndoSnapshots = 200;
  UndoDebounceMs = 600;

var
  GTrackers: TFPList = nil;

procedure PushSnapshot(var A: TRichMemoSnapshotArray; const S: TRichMemoSnapshot; AMax: integer);
var
  i: integer;
begin
  if Length(A) >= AMax then
  begin
    for i := 0 to AMax - 2 do
      A[i] := A[i + 1];
    SetLength(A, AMax - 1);
  end;
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function PopSnapshot(var A: TRichMemoSnapshotArray; out S: TRichMemoSnapshot): boolean;
begin
  Result := Length(A) > 0;
  if not Result then Exit;
  S := A[High(A)];
  SetLength(A, Length(A) - 1);
end;

type
  TRichMemoUndoTracker = class(TComponent)
  public
    Memo: TRichMemo;
    Baseline: TRichMemoBaseline;
    UndoStack: TRichMemoSnapshotArray;
    RedoStack: TRichMemoSnapshotArray;
    Timer: TTimer;
    Suppress: boolean;
    FInChange: boolean;
    FInUndoRedo: boolean;
    FBatchDepth: integer;
    FDestroyed: boolean;
    UserOnChange: TNotifyEvent;
    UserOnSelectionChange: TNotifyEvent;
    PendingCaretPos: integer;
    PendingCaretLen: integer;
    HasPendingCaret: boolean;
    FBaselineStale: boolean;
    FTrackRtfChanges: boolean;
    constructor Create(AMemo: TRichMemo); reintroduce;
    destructor Destroy; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    procedure BeginBatch;
    procedure EndBatch;
    procedure HandleChange(Sender: TObject);
    procedure HandleSelectionChange(Sender: TObject);
    procedure HandleTimer(Sender: TObject);
    procedure ApplyPendingCaret(Data: PtrInt);
    procedure CaptureBaseline;
    function BuildSnapshot: TRichMemoSnapshot;
    procedure CommitPendingChange;
    procedure MarkBaselineStale;
    procedure ApplyUndo(const S: TRichMemoSnapshot);
    procedure ApplyRedo(const S: TRichMemoSnapshot);
  end;

function FindTracker(AMemo: TRichMemo): TRichMemoUndoTracker;
var
  i: integer;
begin
  Result := nil;
  if not Assigned(GTrackers) then Exit;
  for i := 0 to GTrackers.Count - 1 do
  begin
    Result := TRichMemoUndoTracker(GTrackers[i]);
    if Result.Memo = AMemo then Exit;
  end;
  Result := nil;
end;

constructor TRichMemoUndoTracker.Create(AMemo: TRichMemo);
begin
  inherited Create(nil);
  Memo := AMemo;
  AMemo.FreeNotification(Self);
  Suppress := False;
  FInChange := False;
  FInUndoRedo := False;
  FBatchDepth := 0;
  FDestroyed := False;
  HasPendingCaret := False;
  FBaselineStale := False;
  {$IFDEF LCLGTK2}
  // Serializing the whole RTF buffer on GTK is extremely expensive and runs
  // on every idle tick, which is the main source of stalls during typing.
  // Text changes are still detected through Memo.Text. Formatting-only
  // changes are captured on explicit PushUndoSnapshot calls instead.
  FTrackRtfChanges := False;
  {$ELSE}
  FTrackRtfChanges := True;
  {$ENDIF}
  UserOnChange := AMemo.OnChange;
  UserOnSelectionChange := AMemo.OnSelectionChange;
  Timer := TTimer.Create(nil);
  Timer.Interval := UndoDebounceMs;
  Timer.Enabled := False;
  Timer.OnTimer := @HandleTimer;
  CaptureBaseline;
end;

destructor TRichMemoUndoTracker.Destroy;
begin
  FDestroyed := True;
  if Assigned(Timer) then
  begin
    Timer.Enabled := False;
    FreeAndNil(Timer);
  end;
  if Assigned(Memo) then
    Memo.RemoveFreeNotification(Self);
  inherited Destroy;
end;

procedure TRichMemoUndoTracker.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = Memo) then
  begin
    if Assigned(Timer) then
      Timer.Enabled := False;
    FDestroyed := True;
    Memo := nil;
  end;
end;

procedure TRichMemoUndoTracker.BeginBatch;
begin
  Inc(FBatchDepth);
  if FBatchDepth = 1 then
    Timer.Enabled := False;
end;

procedure TRichMemoUndoTracker.EndBatch;
begin
  if FBatchDepth > 0 then Dec(FBatchDepth);
end;

procedure TRichMemoUndoTracker.CaptureBaseline;
begin
  Baseline.Text := Memo.Text;
  if FTrackRtfChanges then
    Baseline.Rtf := Memo.Rtf;
  GetCaretState(Memo, Baseline.SelStart, Baseline.SelLength);
  // A full refresh clears the stale flag: the RTF baseline now matches the
  // current document state.
  FBaselineStale := False;
end;

function TRichMemoUndoTracker.BuildSnapshot: TRichMemoSnapshot;
var
  CurText, CurRtf: string;
  CurSelStart, CurSelLength: integer;
begin
  Result := Default(TRichMemoSnapshot);
  FillChar(Result, SizeOf(Result), 0);

  CurText := Memo.Text;
  GetCaretState(Memo, CurSelStart, CurSelLength);

  Result.SelStart := CurSelStart;
  Result.SelLength := CurSelLength;

  if Length(CurText) <> Length(Baseline.Text) then
  begin
    Result.Kind := skText;
    ComputeDiff(Baseline.Text, CurText, Result.PrefixChars,
      Result.OldTailChars, Result.NewTailChars, Result.OldTail, Result.NewTail);
    Exit;
  end;

  if CurText <> Baseline.Text then
  begin
    Result.Kind := skText;
    ComputeDiff(Baseline.Text, CurText, Result.PrefixChars,
      Result.OldTailChars, Result.NewTailChars, Result.OldTail, Result.NewTail);
    Exit;
  end;

  // Text is unchanged. If the RTF baseline is stale, the only difference is
  // our own service formatting applied via SuspendUndo/ResumeUndo, so it
  // must not be reported as a user change. HandleTimer refreshes the stale
  // baseline during the next idle window.
  if FBaselineStale then
    Exit;

  // When RTF tracking is disabled we cannot cheaply tell whether the user
  // changed formatting only. Skip the RTF comparison entirely: on GTK
  // calling Memo.Rtf here is what makes typing stall on large documents.
  if not FTrackRtfChanges then
    Exit;

  CurRtf := Memo.Rtf;
  if CurRtf <> Baseline.Rtf then
  begin
    Result.Kind := skRtf;
    Result.Rtf := Baseline.Rtf;
    Exit;
  end;

  Result.Kind := skNone;
end;

procedure TRichMemoUndoTracker.CommitPendingChange;
var
  Snap: TRichMemoSnapshot;
begin
  Snap := BuildSnapshot;
  if Snap.Kind = skNone then Exit;
  Snap.SelStart := Baseline.SelStart;
  Snap.SelLength := Baseline.SelLength;
  PushSnapshot(UndoStack, Snap, MaxUndoSnapshots);
  SetLength(RedoStack, 0);
  CaptureBaseline;
end;

procedure TRichMemoUndoTracker.MarkBaselineStale;
begin
  // Service formatting (spell-check underlines) changed the RTF but not the
  // text. Do not serialize the whole RTF snapshot here: on Linux this can
  // stall the UI for seconds while the user is still interacting. Mark the
  // baseline as stale instead and let the debounce timer refresh it during
  // the next idle window.
  FBaselineStale := True;
  Timer.Enabled := False;
  Timer.Enabled := True;
end;

procedure TRichMemoUndoTracker.ApplyPendingCaret(Data: PtrInt);
begin
  if not HasPendingCaret then Exit;
  HasPendingCaret := False;
  if FDestroyed then Exit;
  if not Assigned(Memo) then Exit;
  if not Memo.HandleAllocated then Exit;
  SetCaretState(Memo, PendingCaretPos, PendingCaretLen);
end;

procedure TRichMemoUndoTracker.ApplyUndo(const S: TRichMemoSnapshot);
var
  CaretPos, CaretLen: integer;
begin
  case S.Kind of
    skText:
    begin
      Memo.SelStart := S.PrefixChars;
      Memo.SelLength := S.NewTailChars;
      Memo.SelText := S.OldTail;
      CaretPos := S.PrefixChars + S.OldTailChars;
      CaretLen := 0;
      {$IFDEF LCLGTK2}
        PendingCaretPos := CaretPos;
        PendingCaretLen := CaretLen;
        HasPendingCaret := True;
        Application.QueueAsyncCall(@ApplyPendingCaret, 0);
      {$ELSE}
      SetCaretState(Memo, CaretPos, CaretLen);
      {$ENDIF}
    end;
    skRtf:
    begin
      Memo.Rtf := S.Rtf;
      {$IFDEF LCLGTK2}
        PendingCaretPos := S.SelStart;
        PendingCaretLen := S.SelLength;
        HasPendingCaret := True;
        Application.QueueAsyncCall(@ApplyPendingCaret, 0);
      {$ELSE}
      SetCaretState(Memo, S.SelStart, S.SelLength);
      {$ENDIF}
    end;
  end;
end;

procedure TRichMemoUndoTracker.ApplyRedo(const S: TRichMemoSnapshot);
var
  CaretPos, CaretLen: integer;
begin
  case S.Kind of
    skText:
    begin
      Memo.SelStart := S.PrefixChars;
      Memo.SelLength := S.OldTailChars;
      Memo.SelText := S.NewTail;
      CaretPos := S.PrefixChars + S.NewTailChars;
      CaretLen := 0;
      {$IFDEF LCLGTK2}
        PendingCaretPos := CaretPos;
        PendingCaretLen := CaretLen;
        HasPendingCaret := True;
        Application.QueueAsyncCall(@ApplyPendingCaret, 0);
      {$ELSE}
      SetCaretState(Memo, CaretPos, CaretLen);
      {$ENDIF}
    end;
    skRtf:
    begin
      Memo.Rtf := S.Rtf;
      {$IFDEF LCLGTK2}
        PendingCaretPos := S.SelStart;
        PendingCaretLen := S.SelLength;
        HasPendingCaret := True;
        Application.QueueAsyncCall(@ApplyPendingCaret, 0);
      {$ELSE}
      SetCaretState(Memo, S.SelStart, S.SelLength);
      {$ENDIF}
    end;
  end;
end;

procedure TRichMemoUndoTracker.HandleChange(Sender: TObject);
begin
  if Suppress or FInChange then Exit;
  FInChange := True;
  try
    // During a batch skip everything, the caller commits changes explicitly
    if FBatchDepth > 0 then Exit;
    // Suppress the user handler during undo and redo, spellcheck would go mad
    if FInUndoRedo then Exit;

    Timer.Enabled := False;
    Timer.Enabled := True;

    if Assigned(UserOnChange) then
      UserOnChange(Sender);
  finally
    FInChange := False;
  end;
end;

procedure TRichMemoUndoTracker.HandleSelectionChange(Sender: TObject);
begin
  if Suppress then Exit;
  if Timer.Enabled then Exit;
  GetCaretState(Memo, Baseline.SelStart, Baseline.SelLength);

  if Assigned(UserOnSelectionChange) then
    UserOnSelectionChange(Sender);
end;

procedure TRichMemoUndoTracker.HandleTimer(Sender: TObject);
var
  Snap: TRichMemoSnapshot;
begin
  Timer.Enabled := False;
  if Suppress then Exit;
  if FInUndoRedo then Exit;

  Snap := BuildSnapshot;
  if Snap.Kind = skNone then
  begin
    // No user change was detected. If service formatting marked the RTF
    // baseline as stale, refresh it now during idle time so subsequent user
    // actions are diffed against the current document state.
    if FBaselineStale then
      CaptureBaseline;
    Exit;
  end;

  Snap.SelStart := Baseline.SelStart;
  Snap.SelLength := Baseline.SelLength;

  PushSnapshot(UndoStack, Snap, MaxUndoSnapshots);
  SetLength(RedoStack, 0);
  CaptureBaseline;
end;

procedure TRichMemoHelper.EnableUndo;
var
  T: TRichMemoUndoTracker;
begin
  if Assigned(FindTracker(Self)) then Exit;
  T := TRichMemoUndoTracker.Create(Self);
  if not Assigned(GTrackers) then
    GTrackers := TFPList.Create;
  GTrackers.Add(T);
  Self.OnChange := @T.HandleChange;
  Self.OnSelectionChange := @T.HandleSelectionChange;
end;

procedure TRichMemoHelper.DisableUndo;
var
  T: TRichMemoUndoTracker;
  Idx: integer;
begin
  T := FindTracker(Self);
  if not Assigned(T) then Exit;
  Idx := GTrackers.IndexOf(T);
  if Idx >= 0 then GTrackers.Delete(Idx);
  Self.OnChange := T.UserOnChange;
  Self.OnSelectionChange := T.UserOnSelectionChange;
  T.Free;
end;

function TRichMemoHelper.IsUndoEnabled: boolean;
begin
  Result := Assigned(FindTracker(Self));
end;

procedure TRichMemoHelper.BeginUndoBatch;
var
  T: TRichMemoUndoTracker;
begin
  T := FindTracker(Self);
  if Assigned(T) then T.BeginBatch;
end;

procedure TRichMemoHelper.EndUndoBatch;
var
  T: TRichMemoUndoTracker;
begin
  T := FindTracker(Self);
  if Assigned(T) then T.EndBatch;
end;

procedure TRichMemoHelper.PushUndoSnapshot;
var
  T: TRichMemoUndoTracker;
begin
  T := FindTracker(Self);
  if not Assigned(T) then Exit;
  T.Timer.Enabled := False;
  T.CommitPendingChange;
end;

procedure TRichMemoHelper.UndoEx;
var
  T: TRichMemoUndoTracker;
  Snap: TRichMemoSnapshot;
  RedoSnap: TRichMemoSnapshot;
begin
  T := FindTracker(Self);
  if not Assigned(T) then
  begin
    {$IFDEF WINDOWS}
    SendMessage(Self.Handle, EM_UNDO, 0, 0);
    {$ENDIF}
    Exit;
  end;

  if T.FInUndoRedo then Exit;
  T.FInUndoRedo := True;
  T.BeginBatch;
  try
    T.Timer.Enabled := False;
    T.CommitPendingChange;

    if not PopSnapshot(T.UndoStack, Snap) then Exit;

    case Snap.Kind of
      skText:
      begin
        RedoSnap := Snap;
        RedoSnap.SelStart := Snap.SelStart + Snap.OldTailChars;
        RedoSnap.SelLength := 0;
      end;
      skRtf:
      begin
        RedoSnap.Kind := skRtf;
        RedoSnap.Rtf := Self.Rtf;
        GetCaretState(Self, RedoSnap.SelStart, RedoSnap.SelLength);
      end;
    end;
    SetLength(T.RedoStack, Length(T.RedoStack) + 1);
    T.RedoStack[High(T.RedoStack)] := RedoSnap;

    T.Suppress := True;
    try
      T.ApplyUndo(Snap);
    finally
      T.Suppress := False;
    end;
    T.CaptureBaseline;
  finally
    T.EndBatch;
    T.FInUndoRedo := False;
  end;
end;

procedure TRichMemoHelper.RedoEx;
var
  T: TRichMemoUndoTracker;
  Snap: TRichMemoSnapshot;
  UndoSnap: TRichMemoSnapshot;
begin
  T := FindTracker(Self);
  if not Assigned(T) then
  begin
    {$IFDEF WINDOWS}
    //SendMessage(Self.Handle, RM_EM_REDO, 0, 0);
    {$ENDIF}
    Exit;
  end;

  if T.FInUndoRedo then Exit;
  T.FInUndoRedo := True;
  T.BeginBatch;
  try
    T.Timer.Enabled := False;
    if not PopSnapshot(T.RedoStack, Snap) then Exit;

    case Snap.Kind of
      skText:
      begin
        UndoSnap := Snap;
        UndoSnap.SelStart := Snap.SelStart + Snap.OldTailChars;
        UndoSnap.SelLength := 0;
      end;
      skRtf:
      begin
        UndoSnap.Kind := skRtf;
        UndoSnap.Rtf := Self.Rtf;
        GetCaretState(Self, UndoSnap.SelStart, UndoSnap.SelLength);
      end;
    end;
    SetLength(T.UndoStack, Length(T.UndoStack) + 1);
    T.UndoStack[High(T.UndoStack)] := UndoSnap;

    T.Suppress := True;
    try
      T.ApplyRedo(Snap);
    finally
      T.Suppress := False;
    end;
    T.CaptureBaseline;
  finally
    T.EndBatch;
    T.FInUndoRedo := False;
  end;
end;

function TRichMemoHelper.CanUndo: boolean;
var
  T: TRichMemoUndoTracker;
begin
  T := FindTracker(Self);
  if not Assigned(T) then
  begin
    {$IFDEF WINDOWS}
    Result := SendMessage(Self.Handle, EM_CANUNDO, 0, 0) <> 0;
    {$ELSE}
    Result := False;
    {$ENDIF}
    Exit;
  end;
  Result := Length(T.UndoStack) > 0;
end;

function TRichMemoHelper.CanRedo: boolean;
var
  T: TRichMemoUndoTracker;
begin
  T := FindTracker(Self);
  if not Assigned(T) then
  begin
    {$IFDEF WINDOWS}
    //Result := SendMessage(Self.Handle, RM_EM_CANREDO, 0, 0) <> 0;
    {$ELSE}
    Result := False;
    {$ENDIF}
    Exit;
  end;
  Result := Length(T.RedoStack) > 0;
end;

procedure TRichMemoHelper.ClearUndoHistory;
var
  T: TRichMemoUndoTracker;
begin
  T := FindTracker(Self);
  if not Assigned(T) then
  begin
    {$IFDEF WINDOWS}
    SendMessage(Self.Handle, EM_EMPTYUNDOBUFFER, 0, 0);
    {$ENDIF}
    Exit;
  end;
  SetLength(T.UndoStack, 0);
  SetLength(T.RedoStack, 0);
  T.CaptureBaseline;
end;

function TRichMemoHelper.PasteFromClipboardEx(AUseHtmlFormat: boolean = True): boolean;
var
  HtmlText: string = '';
  RtfText: string = '';
  {$IFDEF WINDOWS}
  TempStream: TMemoryStream = nil;
  SavedFormats: TClipboardFormatDataArray = nil;
  {$ENDIF}
begin
  Result := False;

  if AUseHtmlFormat then
    HtmlText := GetHtmlFromClipboard
  else
    HtmlText := Clipboard.AsText;

  if HtmlText = '' then Exit;

  if not AUseHtmlFormat then
  begin
    BeginUndoBatch;
    try
      Self.SelText := HtmlText;
    finally
      EndUndoBatch;
    end;
    PushUndoSnapshot;
    Result := True;
    Exit;
  end;

  {$IFDEF WINDOWS}
  RtfText := ConvertHtmlToRtf(HtmlText, Self.GetActualFontSize);
  if RtfText = '' then Exit;

  // Save current clipboard content before modifying it
  SavedFormats := Clipboard.SaveAllFormats;
  try
    // Place RTF on the clipboard temporarily to use built-in pasting
    EnsureRtfFormatRegistered;
    Clipboard.Open;
    try
      Clipboard.Clear;
      TempStream := TMemoryStream.Create;
      try
        TempStream.WriteBuffer(RtfText[1], Length(RtfText));
        TempStream.Position := 0;
        Clipboard.AddFormat(CF_RTF_FORMAT, TempStream);
      finally
        TempStream.Free;
      end;
    finally
      Clipboard.Close;
    end;

    BeginUndoBatch;
    try
      // Standard paste inserts at the current cursor position
      Self.PasteFromClipboard;
    finally
      EndUndoBatch;
    end;
    PushUndoSnapshot;
    Result := True;
  finally
    // Restore the original clipboard content
    Clipboard.RestoreAllFormats(SavedFormats);
  end;
  {$ELSE}
  RtfText := ConvertHtmlToRtf(HtmlText, Self.GetActualFontSize, True, True);
  if RtfText = '' then Exit;
  Self.InsertRtfAtCursor(RtfText);
  Result := True;
  {$ENDIF}
end;

function TRichMemoHelper.CopyToClipboardEx: boolean;
  {$IFDEF WINDOWS}
var
  RtfText: string = '';
  HtmlText: string = '';
  PlainText: string = '';
  ms: TMemoryStream = nil;
  {$ENDIF}
begin
  Result := False;

  {$IFDEF WINDOWS}
  if Self.SelLength = 0 then Exit;

  EnsureRtfFormatRegistered;
  EnsureHtmlFormatRegistered;

  // Built-in copy copies the selected fragment (RTF and plain text)
  Self.CopyToClipboard;

  if not Clipboard.HasFormat(CF_RTF_FORMAT) then Exit;

  ms := TMemoryStream.Create;
  try
    Clipboard.GetFormat(CF_RTF_FORMAT, ms);
    ms.Position := 0;
    SetLength(RtfText, ms.Size);
    if ms.Size > 0 then
      ms.ReadBuffer(RtfText[1], ms.Size);
  finally
    ms.Free;
  end;

  if RtfText = '' then Exit;

  PlainText := Self.SelText;
  HtmlText := ConvertRtfToHtml(RtfText);

  // Add plain text and HTML formats to the existing clipboard contents
  Clipboard.Open;
  try
    if PlainText <> '' then
    begin
      ms := TMemoryStream.Create;
      try
        ms.WriteBuffer(PlainText[1], Length(PlainText));
        ms.Position := 0;
        Clipboard.AddFormat(CF_UNICODETEXT, ms);
      finally
        ms.Free;
      end;
    end;

    if HtmlText <> '' then
    begin
      ms := TMemoryStream.Create;
      try
        ms.WriteBuffer(HtmlText[1], Length(HtmlText));
        ms.Position := 0;
        Clipboard.AddFormat(CF_HTML_FORMAT, ms);
        ms.Position := 0;
        Clipboard.AddFormat(CF_TEXT_HTML_FORMAT, ms);
        ms.Position := 0;
        Clipboard.AddFormat(CF_PUBLIC_HTML_FORMAT, ms);
      finally
        ms.Free;
      end;
    end;
  finally
    Clipboard.Close;
  end;

  Result := True;
  {$ENDIF}

  {$IFDEF LCLGTK2}
  if Self.SelLength = 0 then Exit;
  EmitGtkClipboardSignal(Self, 'copy-clipboard');
  Result := True;
  {$ENDIF}
end;

function TRichMemoHelper.CutToClipboardEx: boolean;
begin
  Result := False;

  {$IFDEF WINDOWS}
  if Self.SelLength = 0 then Exit;

  // Copy selected content to clipboard
  if not Self.CopyToClipboardEx then Exit;
  BeginUndoBatch;
  try
    // Delete the selected text
    Self.SelText := '';
  finally
    EndUndoBatch;
  end;
  PushUndoSnapshot;
  Result := True;
  {$ENDIF}

  {$IFDEF LCLGTK2}
  if Self.SelLength = 0 then Exit;
  BeginUndoBatch;
  try
    EmitGtkClipboardSignal(Self, 'cut-clipboard');
  finally
    EndUndoBatch;
  end;
  PushUndoSnapshot;
  Result := True;
  {$ENDIF}
end;

procedure TRichMemoHelper.CutToClipboardNoTrailingLineBreak;
var
  SelectedText: string;
begin
  // Get the selected text from the RichMemo.
  SelectedText := Self.SelText;

  // Remove any trailing line breaks that might have been added.
  // This loop handles both Windows (#13#10) and Linux (#10) line endings.
  while (Length(SelectedText) > 0) and (SelectedText[Length(SelectedText)] in [#13, #10]) do
    Delete(SelectedText, Length(SelectedText), 1);

  // Put the cleaned text into the clipboard.
  Clipboard.AsText := SelectedText;
  BeginUndoBatch;
  try
    Self.ClearSelection;
  finally
    EndUndoBatch;
  end;
  PushUndoSnapshot;
end;

procedure TRichMemoHelper.PasteWithLineEnding;
var
  s: string;
begin
  // Check for plain text or, on Windows, unicode text
  if Clipboard.HasFormat(CF_TEXT)
  {$IFDEF WINDOWS}
  or Clipboard.HasFormat(CF_UNICODETEXT)
  {$ENDIF}
  then
  begin
    s := Clipboard.AsText;

    s := StringReplace(s, #13#10, #10, [rfReplaceAll]); // Windows CRLF -> LF
    s := StringReplace(s, #13, #10, [rfReplaceAll]);   // Macintosh CR -> LF
    s := StringReplace(s, #10, LineEnding, [rfReplaceAll]); // LF -> platform line ending
    BeginUndoBatch;
    try
      Self.SelText := s;
    finally
      EndUndoBatch;
    end;
    PushUndoSnapshot;
  end;
end;

procedure TRichMemoHelper.InsertRtfAtCursor(const ARtf: string);
var
  Marker: string = '@@RTFCURSOR@@';
  FullRtf: string;
  OriginalRtf: string;
  Before: string;
  After: string;
  MarkerPosRtf: integer;
  MarkerPosText: integer;
  MarkerCharPos: integer;
begin
  if ARtf = '' then Exit;

  BeginUndoBatch;
  try
    OriginalRtf := Self.Rtf;

    // Replace current selection with the marker.
    Self.SelText := Marker;

    // Get the RTF containing the marker.
    FullRtf := Self.Rtf;

    MarkerPosRtf := Pos(Marker, FullRtf);
    if MarkerPosRtf = 0 then
    begin
      Self.Rtf := OriginalRtf;
      Exit;
    end;

    // Replace the marker with the RTF fragment followed by the marker.
    Before := Copy(FullRtf, 1, MarkerPosRtf - 1);
    After := Copy(FullRtf, MarkerPosRtf + Length(Marker), MaxInt);

    Self.Rtf := Before + ARtf + Marker + After;

    // Find the marker in the resulting plain text.
    MarkerPosText := Pos(Marker, Self.Text);
    if MarkerPosText = 0 then
    begin
      Self.Rtf := OriginalRtf;
      Exit;
    end;

    // Pos() returns a UTF-8 byte position.
    // RichMemo.SelStart expects a character position.
    MarkerCharPos := UTF8Length(Copy(Self.Text, 1, MarkerPosText - 1));

    // Delete the marker.
    Self.SelStart := MarkerCharPos;
    Self.SelLength := UTF8Length(Marker);
    Self.SelText := '';

    // Cursor is now exactly where the marker was.
    Self.SelLength := 0;
  finally
    EndUndoBatch;
  end;

  PushUndoSnapshot;
end;

function TRichMemoHelper.HasRichFormatting: boolean;
const
  // Local list of formatting commands. \fs is included but handled specially.
  FormattingCommands: array[0..17] of string = (
    '\b', '\i', '\ul', '\cf', '\highlight',
    '\ql', '\qc', '\qj', '\li', '\ri', '\sa', '\sb', '\tx',
    '\strike', '\sub', '\super', '\caps', '\fs');
var
  rtfText: string = '';
  plainText: string = '';
  i: integer = 0;
  searchPos: integer = 0;
  foundPos: integer = 0;
  cmd: string = '';
  paramPos: integer = 0;
  paramValue: integer = 0;
  hasParam: boolean = False;
  isNegative: boolean = False;
  fsFirstValue: integer = 0;
  fsFirstSet: boolean = False;
begin
  Result := False;
  plainText := Self.Text;
  if plainText = '' then Exit; // Empty document cannot have formatting

  rtfText := Self.Rtf;
  if rtfText = '' then Exit;

  // Check for explicit formatting commands, skipping escaped backslashes
  for i := Low(FormattingCommands) to High(FormattingCommands) do
  begin
    cmd := FormattingCommands[i];
    searchPos := 1;
    repeat
      foundPos := PosEx(cmd, rtfText, searchPos);
      if foundPos > 0 then
      begin
        // If the backslash is escaped, it is literal text, not a command
        if not rtfText.IsEscapedBackslash(foundPos) then
        begin
          // Try to read an optional numeric parameter after the command
          paramPos := foundPos + Length(cmd);
          while (paramPos <= Length(rtfText)) and (rtfText[paramPos] = ' ') do
            Inc(paramPos);

          hasParam := False;
          paramValue := 0;
          isNegative := False;
          if (paramPos <= Length(rtfText)) and (rtfText[paramPos] in ['0'..'9', '-']) then
          begin
            hasParam := True;
            if rtfText[paramPos] = '-' then
            begin
              isNegative := True;
              Inc(paramPos);
            end;
            while (paramPos <= Length(rtfText)) and (rtfText[paramPos] in ['0'..'9']) do
            begin
              paramValue := paramValue * 10 + Ord(rtfText[paramPos]) - Ord('0');
              Inc(paramPos);
            end;
            if isNegative then
              paramValue := -paramValue;
          end;

          // Decide whether this command really indicates formatting
          if cmd = '\fs' then
          begin
            // Font size is formatting only if it differs from the first seen value
            if hasParam then
            begin
              if not fsFirstSet then
              begin
                fsFirstValue := paramValue;
                fsFirstSet := True;
              end
              else if paramValue <> fsFirstValue then
              begin
                Result := True;
                Exit;
              end;
            end;
          end
          else if cmd = '\ql' then
          begin
            // Left alignment is default, ignore
          end
          else if (cmd = '\b') or (cmd = '\i') or (cmd = '\ul') or (cmd = '\strike') or (cmd = '\sub') or
            (cmd = '\super') or (cmd = '\caps') then
          begin
            // These commands enable formatting; parameter 0 disables it
            if (not hasParam) or (paramValue <> 0) then
            begin
              Result := True;
              Exit;
            end;
          end
          else
          begin
            // Other commands with numeric parameter (e.g. \li, \ri, \sa, \sb, \tx, \cf, \highlight)
            if hasParam and (paramValue <> 0) then
            begin
              Result := True;
              Exit;
            end;
            // If no parameter, consider it formatting
            if not hasParam then
            begin
              Result := True;
              Exit;
            end;
          end;
        end;
        searchPos := foundPos + 1;
      end;
    until foundPos = 0;
  end;
end;

procedure TRichMemoHelper.ApplyBidiMode;
{$IFDEF WINDOWS}
type
  // PARAFORMAT2 structure Windows API.
  TParaFormat2 = record
    cbSize: UINT;
    dwMask: DWORD;
    wNumbering: WORD;
    wEffects: WORD;
    dxStartIndent: Longint;
    dxRightIndent: Longint;
    dxOffset: Longint;
    wAlignment: WORD;
    cTabCount: Smallint;
    rgxTabs: array[0..31] of Longint;
    dySpaceBefore: Longint;
    dySpaceAfter: Longint;
    dyLineSpacing: Longint;
    sStyle: Smallint;
    bLineSpacingRule: Byte;
    bOutlineLevel: Byte;
    wShadingWeight: WORD;
    wShadingStyle: WORD;
    wNumberingStart: WORD;
    wNumberingStyle: WORD;
    wNumberingTab: WORD;
    wBorderSpace: WORD;
    wBorderWidth: WORD;
    wBorders: WORD;
  end;

  TCharRange = record
    cpMin: Longint;
    cpMax: Longint;
  end;

const
  EM_EXSETSEL = WM_USER + 55;
  EM_SETPARAFORMAT = WM_USER + 71;
  EM_GETSCROLLPOS = WM_USER + 221;
  EM_SETSCROLLPOS = WM_USER + 222;

  PFM_RTLPARA = $00010000;
  PFE_RTLPARA = $00000001;

var
  PF: TParaFormat2;
  CR: TCharRange;
  SavedSelStart: Integer;
  SavedSelLength: Integer;
  ScrollPos: TPoint;
  DesiredRTL: Boolean;
{$ENDIF}
begin
  {$IFDEF WINDOWS}

  DesiredRTL := Self.BidiMode in
    [bdRightToLeft, bdRightToLeftReadingOnly];

  // Save current selection.
  SavedSelStart := Self.SelStart;
  SavedSelLength := Self.SelLength;

  // Save scroll position.
  ScrollPos := Default(TPoint);

  {$HINTS OFF}
  SendMessage(Handle, EM_GETSCROLLPOS, 0, LPARAM(@ScrollPos));
  {$HINTS ON}

  PF := Default(TParaFormat2);
  PF.cbSize := SizeOf(PF);
  PF.dwMask := PFM_RTLPARA;

  if DesiredRTL then
    PF.wEffects := PFE_RTLPARA;

  // Prevent repainting while changing the selection and paragraph format.
  {$HINTS OFF}
  SendMessage(Handle, WM_SETREDRAW, WPARAM(False), 0);
  {$HINTS ON}

  try
    // Select the entire document.
    CR.cpMin := 0;
    CR.cpMax := Self.GetTextLen;

    {$HINTS OFF}
    SendMessage(Handle, EM_EXSETSEL, 0, LPARAM(@CR));
    {$HINTS ON}

    // Apply RTL/LTR paragraph direction.
    {$HINTS OFF}
    SendMessage(Handle, EM_SETPARAFORMAT, 0, LPARAM(@PF));
    {$HINTS ON}

    // Restore original selection.
    CR.cpMin := SavedSelStart;
    CR.cpMax := SavedSelStart + SavedSelLength;

    {$HINTS OFF}
    SendMessage(Handle, EM_EXSETSEL, 0, LPARAM(@CR));

    // Restore scroll position.
    SendMessage(Handle, EM_SETSCROLLPOS, 0, LPARAM(@ScrollPos));

    // Re-enable repainting.
    SendMessage(Handle, WM_SETREDRAW, WPARAM(True), 0);
    {$HINTS ON}
  finally
    // Make sure redraw is always enabled.
    {$HINTS OFF}
    SendMessage(Handle, WM_SETREDRAW, WPARAM(True), 0);
    {$HINTS ON}
  end;

  // Let Windows repaint normally without forcing immediate redraw.
  InvalidateRect(Handle, nil, False);

  {$ENDIF}
end;

function TRichMemoHelper.GetTextHeight(AText: string): integer;
var
  Bmp: Graphics.TBitmap;
  TextRect: TRect;
  Flags: cardinal;
  LogicalWidth: integer; // Logical width for DrawText
begin
  if AText = '' then
    Exit(0);

  // RichEdit stores soft line breaks (Shift+Enter) as vertical tabs (#11),
  // but DrawText only treats CR, LF and CRLF as line breaks. Normalize
  // every representation to sLineBreak before measuring, otherwise the
  // whole text is seen as a single line
  AText := StringReplace(AText, #13#10, #10, [rfReplaceAll]);
  AText := StringReplace(AText, #11, #10, [rfReplaceAll]);
  AText := StringReplace(AText, #10, sLineBreak, [rfReplaceAll]);

  {$IFDEF UNIX}
  AText := StringReplace(AText, sLineBreak, sLineBreak + ' ', [rfReplaceAll]);
  {$ENDIF}

  // Always add LineEnding
  AText := AText + LineEnding + ' ';
  //if (Length(AText) > 0) and (AText[Length(AText)] in [#10, #13]) then
  //  AText := AText + ' ';

  Flags := DT_CALCRECT or DT_EDITCONTROL or DT_NOPREFIX;

  if Self.WordWrap then
    Flags := Flags or DT_WORDBREAK;

  Bmp := Graphics.TBitmap.Create;
  try
    Bmp.Canvas.Font.Assign(Self.Font);

    // Keep original font, adjust only logical width according to zoom
    if Self.WordWrap then
    begin
      // Logical width is the physical width divided by zoom factor
      LogicalWidth := Round((Self.ClientWidth - GetSystemMetrics(SM_CXVSCROLL) - 4) / Self.ZoomFactor);
      TextRect := Types.Rect(0, 0, LogicalWidth, 0);
    end
    else
      TextRect := Types.Rect(0, 0, 32767, 0);

    DrawText(
      Bmp.Canvas.Handle,
      PChar(AText),
      Length(AText),
      TextRect,
      Flags
      );

    // Scale the resulting logical height back to physical pixels
    // Use Ceil to avoid losing a pixel when scaling back to physical pixels
    Result := Ceil((TextRect.Bottom - TextRect.Top) * Self.ZoomFactor);
  finally
    Bmp.Free;
  end;
end;

procedure TRichMemoHelper.ResetParaSpacing;
{$IFDEF WINDOWS}
var
  ParaFormat2: TParaFormat2;
  TextMetric: TTextMetric;
  Bmp: Graphics.TBitmap;
  LineHeightTwips: LongInt;
{$ELSE}
var
  ParaMetric: TParaMetric;
{$ENDIF}
begin
  if Self.HandleAllocated = False then
    Exit;

  {$IFDEF WINDOWS}
  TextMetric := Default(TTextMetric);
  ParaFormat2 := Default(TParaFormat2);

  // Get the real font height in pixels using a temporary bitmap
  Bmp := Graphics.TBitmap.Create;
  try
    Bmp.Canvas.Font.Assign(Self.Font);
    GetTextMetrics(Bmp.Canvas.Handle, TextMetric);
  finally
    Bmp.Free;
  end;

  // Convert font height to twips (1 pixel = 15 twips at 96 DPI)
  LineHeightTwips := TextMetric.tmHeight * 15;

  FillChar(ParaFormat2, SizeOf(ParaFormat2), 0);
  ParaFormat2.cbSize := SizeOf(ParaFormat2);
  ParaFormat2.dwMask := PFM_LINESPACING or PFM_SPACEBEFORE or PFM_SPACEAFTER;
  ParaFormat2.bLineSpacingRule := 4; // Exact line spacing
  ParaFormat2.dyLineSpacing := LineHeightTwips;
  ParaFormat2.dySpaceBefore := 0;
  ParaFormat2.dySpaceAfter := 0;

  {$HINTS OFF}
  SendMessage(Self.Handle, EM_SETPARAFORMAT, 0, LPARAM(@ParaFormat2));
  {$HINTS ON}
  {$ELSE}
  BeginUndoBatch;
  try
    ParaMetric := Default(TParaMetric);
    InitParaMetric(ParaMetric);
    ParaMetric.LineSpacing := DefLineSpacing;
    ParaMetric.SpaceBefore := 0;
    ParaMetric.SpaceAfter := 0;
    Self.SetParaMetric(0, Self.GetTextLen, ParaMetric);
  finally
    EndUndoBatch;
  end;
  {$ENDIF}
end;

function TRichMemoHelper.GetBottomSpace: integer;
begin
  if Self.Text = '' then
  begin
    Result := Self.ClientHeight;
    Exit;
  end;

  // Free space = visible height - actual text height
  Result := Self.ClientHeight - Self.GetTextHeight(Self.Text);

  if Result < 0 then
    Result := 0;
end;

procedure TRichMemoHelper.SaveToFileSafe(AFileName: string);
begin
  try
    with TStringList.Create do
    try
      Text := Self.Text;
      TrailingLineBreak := False;
      SaveToFile(AFileName);
    finally
      Free;
    end;
  except
    on E: Exception do
      // Do nothing if can't save current text files
  end;
end;

procedure TRichMemoHelper.MemoTokenAtPos(APos: integer; const AExtraChars: unicodestring);
var
  Value: unicodestring;
  Pos1, LeftIdx, RightIdx, LenText: integer;
  Ch: widechar;

  function IsLetterOrDigit(ch: widechar): boolean;
  begin
    Result := (ch in ['0'..'9', 'A'..'Z', 'a'..'z']) or (ch > #127);
  end;

  function IsExtraChar(ACh: widechar): boolean;
  begin
    Result := Pos(ACh, AExtraChars) > 0;
  end;

  function CharType(ACh: widechar): integer;
  begin
    // 1 = letter or digit
    // 2 = space
    // 3 = other symbol
    if IsLetterOrDigit(ACh) or IsExtraChar(ACh) then
      Result := 1
    else if ACh = ' ' then
      Result := 2
    else
      Result := 3;
  end;

begin
  Value := unicodestring(Self.Text);
  LenText := Length(Value);
  if LenText = 0 then Exit;

  Pos1 := APos + 1;
  if Pos1 < 1 then Pos1 := 1;
  if Pos1 > LenText then Pos1 := LenText;

  Ch := Value[Pos1];
  LeftIdx := Pos1;
  RightIdx := Pos1 + 1;

  case CharType(Ch) of
    1:
    begin
      while (LeftIdx > 1) and (CharType(Value[LeftIdx - 1]) = 1) do Dec(LeftIdx);
      while (RightIdx <= LenText) and (CharType(Value[RightIdx]) = 1) do Inc(RightIdx);

      while (LeftIdx > 2) and (Value[LeftIdx - 1] = '.') and (CharType(Value[LeftIdx - 2]) = 1) do
      begin
        Dec(LeftIdx);
        while (LeftIdx > 1) and (CharType(Value[LeftIdx - 1]) = 1) do Dec(LeftIdx);
      end;

      while (RightIdx < LenText) and (Value[RightIdx] = '.') and (CharType(Value[RightIdx + 1]) = 1) do
      begin
        Inc(RightIdx);
        while (RightIdx <= LenText) and (CharType(Value[RightIdx]) = 1) do Inc(RightIdx);
      end;
    end;

    2:
    begin
      while (LeftIdx > 1) and (Value[LeftIdx - 1] = ' ') do Dec(LeftIdx);
      while (RightIdx <= LenText) and (Value[RightIdx] = ' ') do Inc(RightIdx);
    end;

    3:
    begin
      while (LeftIdx > 1) and (Value[LeftIdx - 1] = Ch) do Dec(LeftIdx);
      while (RightIdx <= LenText) and (Value[RightIdx] = Ch) do Inc(RightIdx);
    end;
  end;

  Self.SelStart := LeftIdx - 1;
  Self.SelLength := RightIdx - LeftIdx;
end;

procedure TRichMemoHelper.SuspendUndo;
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
var
  T: TRichMemoUndoTracker;
begin
  T := FindTracker(Self);
  if Assigned(T) then
  begin
    // Flush any change still waiting in the debounce timer before
    // suppression, otherwise ResumeUndo would silently swallow it when it
    // captures a new baseline.
    T.Timer.Enabled := False;
    T.CommitPendingChange;
    T.Suppress := True;
  end;
  {$IFDEF WINDOWS}
  RichEditOle := nil;
  DispParams:=Default(TDispParams);
  {$HINTS OFF}
  if SendMessage(Self.Handle, EM_GETOLEINTERFACE, 0, LPARAM(@RichEditOle)) = 0 then Exit;
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

procedure TRichMemoHelper.ResumeUndo;
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
var
  T: TRichMemoUndoTracker;
begin
  {$IFDEF WINDOWS}
  RichEditOle := nil;
  DispParams:=Default(TDispParams);
  {$HINTS OFF}
  if SendMessage(Self.Handle, EM_GETOLEINTERFACE, 0, LPARAM(@RichEditOle)) = 0 then Exit;
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
  T := FindTracker(Self);
  if Assigned(T) then
  begin
    T.Suppress := False;
    // Do not reserialize the RTF baseline here: this method runs during
    // active spell-check processing, and a full RTF snapshot on a large
    // document can stall the UI for seconds. Mark the baseline as stale
    // instead; the debounce timer refreshes it once the user stops
    // interacting.
    T.MarkBaselineStale;
  end;
end;

procedure TRichMemoHelper.SetLeftIndent(AIndentPixels: integer = 3);
{$IFDEF WINDOWS}
type
  TParaFormat2 = record
    cbSize: UINT;
    dwMask: DWORD;
    wNumbering: WORD;
    wEffects: WORD;
    dxStartIndent: Longint;
    dxRightIndent: Longint;
    dxOffset: Longint;
    wAlignment: WORD;
    cTabCount: Smallint;
    rgxTabs: array[0..31] of Longint;
    dySpaceBefore: Longint;
    dySpaceAfter: Longint;
    dyLineSpacing: Longint;
    sStyle: Smallint;
    bLineSpacingRule: Byte;
    bOutlineLevel: Byte;
    wShadingWeight: WORD;
    wShadingStyle: WORD;
    wNumberingStart: WORD;
    wNumberingStyle: WORD;
    wNumberingTab: WORD;
    wBorderSpace: WORD;
    wBorderWidth: WORD;
    wBorders: WORD;
  end;

  TCharRange = record
    cpMin: Longint;
    cpMax: Longint;
  end;

const
  EM_EXSETSEL = WM_USER + 55;
  EM_SETPARAFORMAT = WM_USER + 71;
  EM_GETSCROLLPOS = WM_USER + 221;
  EM_SETSCROLLPOS = WM_USER + 222;
  PFM_STARTINDENT = $00000001;

var
  PF: TParaFormat2;
  CR: TCharRange;
  SavedSelStart: Integer;
  SavedSelLength: Integer;
  ScrollPos: TPoint;
  IndentTwips: Integer;
  DC: HDC;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  SuspendUndo;
  try
  if AIndentPixels < 0 then
    AIndentPixels := 0;

  // Convert pixels to twips using screen DPI.
  DC := GetDC(0);
  try
    IndentTwips := MulDiv(AIndentPixels, 1440, GetDeviceCaps(DC, LOGPIXELSX));
  finally
    ReleaseDC(0, DC);
  end;

  // Save current selection.
  SavedSelStart := Self.SelStart;
  SavedSelLength := Self.SelLength;

  // Save scroll position.
  ScrollPos := Default(TPoint);
  {$HINTS OFF}
  SendMessage(Handle, EM_GETSCROLLPOS, 0, LPARAM(@ScrollPos));
  {$HINTS ON}

  PF := Default(TParaFormat2);
  PF.cbSize := SizeOf(PF);
  PF.dwMask := PFM_STARTINDENT;
  PF.dxStartIndent := IndentTwips;

  // Prevent repainting while changing the selection and paragraph format.
  {$HINTS OFF}
  SendMessage(Handle, WM_SETREDRAW, WPARAM(False), 0);
  {$HINTS ON}

  try
    // Select the entire document.
    CR.cpMin := 0;
    CR.cpMax := Self.GetTextLen;

    {$HINTS OFF}
    SendMessage(Handle, EM_EXSETSEL, 0, LPARAM(@CR));
    {$HINTS ON}

    // Apply left indent to all paragraphs.
    {$HINTS OFF}
    SendMessage(Handle, EM_SETPARAFORMAT, 0, LPARAM(@PF));
    {$HINTS ON}

    // Restore original selection.
    CR.cpMin := SavedSelStart;
    CR.cpMax := SavedSelStart + SavedSelLength;

    {$HINTS OFF}
    SendMessage(Handle, EM_EXSETSEL, 0, LPARAM(@CR));

    // Restore scroll position.
    SendMessage(Handle, EM_SETSCROLLPOS, 0, LPARAM(@ScrollPos));

    // Re-enable repainting.
    SendMessage(Handle, WM_SETREDRAW, WPARAM(True), 0);
    {$HINTS ON}
  finally
    // Make sure redraw is always enabled.
    {$HINTS OFF}
    SendMessage(Handle, WM_SETREDRAW, WPARAM(True), 0);
    {$HINTS ON}
  end;

  // Let Windows repaint normally without forcing immediate redraw.
  InvalidateRect(Handle, nil, False);
  finally
    ResumeUndo;
  end;
  {$ENDIF}
end;

procedure TRichMemoHelper.DisableBuiltInDragDrop;
{$IFDEF WINDOWS}
const
  ES_NOOLEDRAGDROP = $0008;
var
  Style: nativeuint;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  HandleNeeded;

  Style := GetWindowLongPtr(Handle, GWL_STYLE);

  // Add the style only if it is not already present.
  if (Style and ES_NOOLEDRAGDROP) = 0 then
    SetWindowLongPtr(Handle, GWL_STYLE, Style or ES_NOOLEDRAGDROP);

  // Revoke any existing OLE drop target (cheap operation).
  RevokeDragDrop(Handle);
  {$ENDIF}
end;

procedure TRichMemoHelper.EnableScrollbarFix(AParentPanel: TWinControl);
begin
  {$IFDEF WINDOWS}
  if not (Self is TWinControl) then Exit;
  if not Assigned(AParentPanel) then Exit;

  TWinControl(Self).HandleNeeded;
  AParentPanel.HandleNeeded;

  if not TWinControl(Self).HandleAllocated then Exit;
  if not AParentPanel.HandleAllocated then Exit;

  SetProp(
    TWinControl(Self).Handle,
    'ScrollFixParentPanel',
    Pointer(AParentPanel));

  SetTimer(
    TWinControl(Self).Handle,
    SCROLLBAR_FIX_TIMER_ID,
    SCROLLBAR_FIX_INTERVAL,
    @RichMemoScrollbarFixTimer);
  {$ENDIF}
end;

procedure TRichMemoHelper.SetTextSafe(const AText: string);
var
  ZoomFactor: double;
begin
  ZoomFactor := Self.ZoomFactor;
  Self.Text := AText;
  Self.ZoomFactor := ZoomFactor;
end;

procedure TRichMemoHelper.ClearWithUndo;
var
  TextLen: integer;
begin
  if Self.Text = '' then Exit;
  TextLen := Length(UTF8ToUTF16(Self.Text));
  BeginUndoBatch;
  try
    // Select all text
    Self.SelStart := 0;
    Self.SelLength := TextLen;

    // Replacing selection with empty string creates an undo point
    Self.SelText := '';

    // Move cursor to the beginning
    Self.SelStart := 0;
    Self.SelLength := 0;
  finally
    EndUndoBatch;
  end;
  PushUndoSnapshot;
end;

procedure TRichMemoHelper.UpdateState(AIndentPixels: integer = 3; AResetParaSpacing: boolean = False);
begin
  if not Self.Visible then Exit;
  if AIndentPixels > 1 then
    Self.SetLeftIndent(AIndentPixels);
  Self.ApplyBidiMode;
  if AResetParaSpacing then
    Self.ResetParaSpacing;
end;

finalization
  if Assigned(GTrackers) then
  begin
    while GTrackers.Count > 0 do
    begin
      TRichMemoUndoTracker(GTrackers[0]).Free;
      GTrackers.Delete(0);
    end;
    FreeAndNil(GTrackers);
  end;

end.
