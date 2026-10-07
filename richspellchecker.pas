//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit RichSpellChecker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Menus, Graphics, Types, ExtCtrls, RichMemo, RichMemoHelper;

type
  TSpellCheckOption = (scoSpelling, scoComprehensiveSpelling);
  TSpellCheckOptions = set of TSpellCheckOption;

  TSpellError = record
    Offset: integer;
    Length: integer;
    Message: string;
    Replacements: array of string;
    Color: TColor;
  end;
  PSpellError = ^TSpellError;
  TSpellErrorArray = array of TSpellError;

  TRichSpellChecker = class
  private
    FRichMemo: TRichMemo;
    FMenu: TPopupMenu;
    FErrors: TList;
    FCurrentError: PSpellError;
    FOnSpellCheckNeeded: TNotifyEvent;
    FApplyImmediately: boolean;
    FContextCaretPos: integer; // caret position when context menu was invoked
    FUpdateLock: integer; // blocks context menu while updates are in progress
    FErrorsAtBeginUpdate: integer; // error count when the outermost BeginUpdate was called
    FTargetPopupMenu: TPopupMenu; // external popup menu to host replacements
    FInjectedItems: TList; // dynamically added menu items for later removal
    FSubMenu: boolean; // if True, create a submenu for suggestions
    FSubMenuCaption: string; // caption of the submenu
    FSubMenuIndex: integer; // insertion index in the popup menu
    FIsShowingOurMenu: boolean; // indicates the popup was opened by our ShowContextMenu
    FOriginalPopupOnPopup: TNotifyEvent; // saved original OnPopup handler
    FOriginalPopupOnClose: TNotifyEvent; // saved original OnClose handler
    FMemoChangeOnReplace: boolean; // if True, do not block RichMemo.OnChange during replacement
    FTimer: TTimer; // delayed cleanup timer
    function GetErrorAtTextPos(ATextPos: integer): PSpellError;
    procedure ApplyUnderlineToError(AError: PSpellError);
    procedure ClearUnderlines;
    procedure ReplacementClick(Sender: TObject);
    function GetCharIndexAtPos(X, Y: integer): integer;
    procedure ClearInjectedItems;
    procedure SetTargetPopupMenu(const AValue: TPopupMenu);
    procedure PopupCloseHandler(Sender: TObject);
    procedure TimerHandler(Sender: TObject);
  public
    constructor Create(ARichMemo: TRichMemo);
    destructor Destroy; override;
    procedure Clear;
    procedure BeginUpdate;
    procedure EndUpdate;
    procedure AddError(AOffset, ALength: integer; const AMessage: string; const AReplacements: array of string; AColor: TColor = clRed);
    procedure ApplyUnderlines;
    // Draws only errors from AStartIndex to the end of the list. Used by
    // EndUpdate to avoid redrawing the entire accumulated error list on
    // every incremental update, which would be O(N^2) across many chunks.
    procedure ApplyUnderlinesFrom(AStartIndex: integer);
    function ShowContextMenu(X, Y: integer): boolean;
    procedure ReplaceError(AError: PSpellError; const ANewText: string; NewCaretPos: integer = -1);
    // Remove a single error from the list and clear its underline
    procedure RemoveError(AError: PSpellError; ANewLength: integer);
    // Updates the suggestion list of an existing error that matches the
    // given offset and length. Used by the two-phase check to attach
    // suggestions after the underlines have already been drawn
    procedure UpdateErrorSuggestions(AOffset, ALength: integer; const AReplacements: array of string);
    property OnSpellCheckNeeded: TNotifyEvent read FOnSpellCheckNeeded write FOnSpellCheckNeeded;
    property PopupMenu: TPopupMenu read FTargetPopupMenu write SetTargetPopupMenu;
    property SubMenu: boolean read FSubMenu write FSubMenu default False;
    property SubMenuCaption: string read FSubMenuCaption write FSubMenuCaption;
    property SubMenuIndex: integer read FSubMenuIndex write FSubMenuIndex default 0;
    // When True, RichMemo.OnChange is left active during a replacement from the
    // suggestions menu. When False (default), OnChange is temporarily cleared
    // to avoid reentrant spell checking.
    property MemoChangeOnReplace: boolean read FMemoChangeOnReplace write FMemoChangeOnReplace default False;
  end;

// Batch-draws the given errors on ARichMemo. Existing underlines are not
// cleared here - callers decide whether a clear is needed first. Used both
// by TRichSpellChecker.ApplyUnderlines (list of pointers) and by the
// standalone DrawSpellErrors (array of records).
procedure DrawSpellErrorsBatch(ARichMemo: TRichMemo; AErrors: TList; AStartIndex: integer = 0);
// Standalone helpers that draw or clear spell-check underlines on any RichMemo
// without creating a TRichSpellChecker instance. Handy when the same text is
// shown in more than one control and all of them need the same underlines.
procedure ClearSpellErrors(ARichMemo: TRichMemo);
procedure DrawSpellUnderline(ARichMemo: TRichMemo; AOffset, ALength: integer; AColor: TColor);
procedure DrawSpellErrors(ARichMemo: TRichMemo; const AErrors: TSpellErrorArray);

implementation

{$IFDEF WINDOWS}
  uses Windows, LCLType, ComObj, Variants;
{$ENDIF}
{$IFDEF LCLGTK2}
  uses gtk2;
{$ENDIF}
{$IFDEF LCLGTK3}
  uses gtk3, gdk3, glib2;
{$ENDIF}

{$IFDEF WINDOWS}

const
  EM_EXSETSEL = WM_USER + 55;
  EM_SETCHARFORMAT = WM_USER + 68;
  EM_CHARFROMPOS = $00D7;

  SCF_SELECTION = $0001;

  CFM_UNDERLINE = $00000004;
  CFM_UNDERLINETYPE = $00800000;
  CFM_UNDERLINECOLOR = $10000000;

  CFE_UNDERLINE = $00000004;
  CFU_UNDERLINENONE = 0;
  CFU_UNDERLINEWAVE = 8;

  EM_GETSCROLLPOS = WM_USER + 221;
  EM_SETSCROLLPOS = WM_USER + 222;

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

  // Windows 8 and later use a different set of underline color indices
  // in RichEdit (red is 0x06 instead of 0x05)
  function UsesNewUnderlineColorLayout: boolean;
  begin
    Result := (Win32MajorVersion > 6) or
              ((Win32MajorVersion = 6) and (Win32MinorVersion >= 2));
  end;

  function MapColorToWinUnderline(AColor: TColor): Byte;
  const
    // Windows underline color indices (user may adjust these)
    UNDERLINE_COLOR_BLACK   = 0;
    UNDERLINE_COLOR_BLUE    = 1;
    UNDERLINE_COLOR_GREEN   = 3;
    UNDERLINE_COLOR_FUCHSIA = 4;
  var
    RedIndex: Byte;
  begin
    if UsesNewUnderlineColorLayout then
      RedIndex := 6  // Windows 8 and later
    else
      RedIndex := 5; // Windows XP, Vista, 7 and RichEdit 4.1

    case AColor of
      clBlack:   Result := UNDERLINE_COLOR_BLACK;
      clBlue:    Result := UNDERLINE_COLOR_BLUE;
      clGreen:   Result := UNDERLINE_COLOR_GREEN;
      clFuchsia: Result := UNDERLINE_COLOR_FUCHSIA;
      clRed:     Result := RedIndex;
    else
      // Fallback to red for any unlisted color
      Result := RedIndex;
    end;
  end;
{$ENDIF}

{%Region -fold Standalone methods}

// Wraps a batch of formatting calls into a single GTK user action and
// freezes child-notify signals so the widget is not redrawn after every
// SetRangeParams. This is the closest GTK equivalent of WM_SETREDRAW and
// it removes both the visible jitter and most of the lag on large batches.
// On other widget sets the procedures are no-ops.
{$IF defined(LCLGTK2) or defined(LCLGTK3)}
procedure GtkBeginBatch(ARichMemo: TRichMemo);
var
  Widget: PGtkWidget;
begin
  if not Assigned(ARichMemo) then
    Exit;
  {$HINTS OFF}
  Widget := PGtkWidget(ARichMemo.Handle);
  {$HINTS ON}
  if Widget = nil then
    Exit;
  gtk_widget_freeze_child_notify(Widget);
  gtk_text_buffer_begin_user_action(gtk_text_view_get_buffer(GTK_TEXT_VIEW(Widget)));
end;

procedure GtkEndBatch(ARichMemo: TRichMemo);
var
  Widget: PGtkWidget;
begin
  if not Assigned(ARichMemo) then
    Exit;
  {$HINTS OFF}
  Widget := PGtkWidget(ARichMemo.Handle);
  {$HINTS ON}
  if Widget = nil then
    Exit;
  gtk_text_buffer_end_user_action(gtk_text_view_get_buffer(GTK_TEXT_VIEW(Widget)));
  gtk_widget_thaw_child_notify(Widget);
end;
{$ELSE}

procedure GtkBeginBatch(ARichMemo: TRichMemo);
begin
end;

procedure GtkEndBatch(ARichMemo: TRichMemo);
begin
end;
{$IFEND}

// Low level underline drawing used inside a batch. The caller owns the
// undo suspension and the selection save/restore, so this helper does not
// touch them. Used by DrawSpellErrorsBatch to avoid two redundant
// SendMessage calls per error on Windows, which is the main speedup for
// documents with thousands of underlines.
procedure DrawSpellUnderlineFast(ARichMemo: TRichMemo; AOffset, ALength: integer; AColor: TColor);
{$IFDEF WINDOWS}
var
  cf: CHARFORMAT2W;
  cr: CHARRANGE;
{$ENDIF}
begin
  if not Assigned(ARichMemo) then
    Exit;

  {$IFDEF WINDOWS}
  cr.cpMin := AOffset;
  cr.cpMax := AOffset + ALength;
  {$HINTS OFF}
  SendMessage(ARichMemo.Handle, EM_EXSETSEL, 0, LPARAM(PtrInt(@cr)));
  {$HINTS ON}

  cf := Default(CHARFORMAT2W);
  cf.cbSize := SizeOf(cf);
  cf.dwMask := CFM_UNDERLINE or CFM_UNDERLINETYPE or CFM_UNDERLINECOLOR or CFM_COLOR;
  cf.dwEffects := CFE_UNDERLINE;
  cf.bUnderlineType := CFU_UNDERLINEWAVE;
  cf.bUnderlineColor := MapColorToWinUnderline(AColor);
  cf.crTextColor := GetSysColor(COLOR_WINDOWTEXT);

  {$HINTS OFF}
  SendMessage(ARichMemo.Handle, EM_SETCHARFORMAT, SCF_SELECTION, LPARAM(PtrInt(@cf)));
  {$HINTS ON}
  {$ELSE}
  ARichMemo.SetRangeParams(
    AOffset,
    ALength,
    [tmm_Styles, tmm_Color],
    '',
    0,
    AColor,
    [],
    []
    );
  {$ENDIF}
end;

procedure DrawSpellErrorsBatch(ARichMemo: TRichMemo; AErrors: TList; AStartIndex: integer = 0);
var
  i: integer;
  {$IFDEF WINDOWS}
  scrollPos: TPoint;
  cr: CHARRANGE;
  {$ENDIF}
  OldSelStart, OldSelLength: integer;
begin
  if not Assigned(ARichMemo) then
    Exit;
  if AStartIndex < 0 then
    AStartIndex := 0;
  if AStartIndex >= AErrors.Count then
    Exit;

  // Save caret position
  OldSelStart := ARichMemo.SelStart;
  OldSelLength := ARichMemo.SelLength;

  {$IFDEF WINDOWS}
  // Save scroll position
  {$HINTS OFF}
  SendMessage(ARichMemo.Handle, EM_GETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
  {$HINTS ON}

  // Suspend Undo for the entire batch of formatting
  ARichMemo.SuspendUndo;
  try
    // Block repainting while applying all underlines
    SendMessage(ARichMemo.Handle, WM_SETREDRAW, 0, 0);
    try
      for i := AStartIndex to AErrors.Count - 1 do
        DrawSpellUnderlineFast(ARichMemo,
          PSpellError(AErrors[i])^.Offset,
          PSpellError(AErrors[i])^.Length,
          PSpellError(AErrors[i])^.Color);
    finally
      // Restore the selection through EM_EXSETSEL directly, bypassing the
      // LCL property setter. The setter performs extra work per call (cache
      // updates and a possible scroll-into-view), which is wasteful when
      // we only need to put the caret back where it was before the batch.
      cr.cpMin := OldSelStart;
      cr.cpMax := OldSelStart + OldSelLength;
      {$HINTS OFF}
      SendMessage(ARichMemo.Handle, EM_EXSETSEL, 0, LPARAM(PtrInt(@cr)));
      {$HINTS ON}
      // Restore scroll position
      {$HINTS OFF}
      SendMessage(ARichMemo.Handle, EM_SETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
      {$HINTS ON}
      // WM_SETREDRAW with 1 already invalidates the whole control and
      // schedules a repaint. An additional Invalidate just forces that
      // repaint to run sooner, which tends to make incremental chunked
      // checks feel heavier because the paint is not batched with others.
      SendMessage(ARichMemo.Handle, WM_SETREDRAW, 1, 0);
      ARichMemo.Invalidate;
    end;
  finally
    ARichMemo.ResumeUndo;
  end;
  {$ELSE}
  // On GTK every SetRangeParams call schedules a synchronous widget update,
  // and restoring the selection after each error forces the view to scroll
  // to the caret. Save the selection once, block intermediate repaints via
  // Lines.BeginUpdate (which is available cross-platform), apply all
  // underlines, and restore the selection only at the end. This removes
  // both the per error scroll jump and most of the lag.
  // The selection is restored only when it actually changed: on GTK even a
  // no-op SelStart assignment makes the widget scroll the caret back into
  // view, which would reset the user's scroll position every time underlines
  // are applied in the background (for example during a visible-only check).
  // GtkBeginBatch/GtkEndBatch group all formatting changes into a single
  // user action and freeze child-notify signals, so the widget is redrawn
  // once at the end instead of after every error.
  // Spell-check underlines are service formatting and must not be recorded
  // in the undo tracker, so suppress undo for the whole batch.
  ARichMemo.SuspendUndo;
  try
    GtkBeginBatch(ARichMemo);
    try
      ARichMemo.Lines.BeginUpdate;
      try
        for i := AStartIndex to AErrors.Count - 1 do
          DrawSpellUnderlineFast(ARichMemo,
            PSpellError(AErrors[i])^.Offset,
            PSpellError(AErrors[i])^.Length,
            PSpellError(AErrors[i])^.Color);
      finally
        if ARichMemo.SelStart <> OldSelStart then
          ARichMemo.SelStart := OldSelStart;
        if ARichMemo.SelLength <> OldSelLength then
          ARichMemo.SelLength := OldSelLength;
        ARichMemo.Lines.EndUpdate;
      end;
    finally
      GtkEndBatch(ARichMemo);
    end;
  finally
    ARichMemo.ResumeUndo;
  end;
  {$ENDIF}
end;

procedure DrawSpellUnderline(ARichMemo: TRichMemo; AOffset, ALength: integer; AColor: TColor);
{$IFDEF WINDOWS}
var
  OldSelStart, OldSelLength: integer;
{$ENDIF}
begin
  if not Assigned(ARichMemo) then
    Exit;

  {$IFDEF WINDOWS}
  // Standalone calls must leave the memo in a clean state: hide the
  // change from the undo tracker and restore the caret position after
  // the underline has been applied, so no selection is left visible.
  OldSelStart := ARichMemo.SelStart;
  OldSelLength := ARichMemo.SelLength;
  ARichMemo.SuspendUndo;
  try
    DrawSpellUnderlineFast(ARichMemo, AOffset, ALength, AColor);
    ARichMemo.SelStart := OldSelStart;
    ARichMemo.SelLength := OldSelLength;
  finally
    ARichMemo.ResumeUndo;
  end;
  {$ELSE}
  // On non Windows widget sets SetRangeParams does not leave a visible
  // selection behind, so the fast path is safe to use directly.
  DrawSpellUnderlineFast(ARichMemo, AOffset, ALength, AColor);
  {$ENDIF}
end;

procedure DrawSpellErrors(ARichMemo: TRichMemo; const AErrors: TSpellErrorArray);
var
  TempList: TList;
  i: integer;
begin
  if not Assigned(ARichMemo) then
    Exit;

  // Drop stale underlines first, then draw fresh ones
  ClearSpellErrors(ARichMemo);

  if Length(AErrors) = 0 then
    Exit;

  // Wrap the array into a temporary pointer list so we can reuse the shared
  // batch routine. Taking address of elements of a dynamic array is safe
  // here because AErrors lives in the caller for the whole call.
  TempList := TList.Create;
  try
    for i := 0 to High(AErrors) do
      TempList.Add(@AErrors[i]);
    DrawSpellErrorsBatch(ARichMemo, TempList);
  finally
    TempList.Free;
  end;
end;

// Removes all text tags from the memo buffer using the native GTK call.
// Unlike SetRangeParams, which adds tag toggles on top of existing ones,
// gtk_text_buffer_remove_all_tags is a single buffer operation. It does
// not remove stale entries from the internal btree, but it may be cheaper
// than a full range SetRangeParams on some GTK versions. The call is
// wrapped in GtkBeginBatch/GtkEndBatch so the widget redraws once, and
// undo is suppressed so the operation is not recorded in the undo history.
// The caret and selection are saved and restored.
// WARNING: this removes every tag in the range, including tags added by
// RichMemo, LCL or other components. Use it only when no other code
// applies tags to the same memo.
procedure RemoveAllTagsNative(ARichMemo: TRichMemo);
{$IFDEF LCLGTK2}
var
  Widget: PGtkWidget = nil;
  Buffer: PGtkTextBuffer = nil;
  StartIter, EndIter: TGtkTextIter;
  OldSelStart: integer = 0;
  OldSelLength: integer = 0;
{$ENDIF}
{$IFDEF LCLGTK3}
var
  Widget: PGtkWidget = nil;
  Buffer: PGtkTextBuffer = nil;
  StartIter, EndIter: TGtkTextIter;
  OldSelStart: integer = 0;
  OldSelLength: integer = 0;
{$ENDIF}
begin
  {$IFDEF LCLGTK2}
  if not Assigned(ARichMemo) then
    Exit;

  // ARichMemo.Handle is a THandle (HWND on Windows, a widget pointer on
  // GTK). Cast it through PGtkWidget the same way GtkBeginBatch does, so
  // the compiler accepts the pointer conversion.
  {$HINTS OFF}
  Widget := PGtkWidget(ARichMemo.Handle);
  {$HINTS ON}
  if Widget = nil then
    Exit;

  Buffer := gtk_text_view_get_buffer(GTK_TEXT_VIEW(Widget));
  if Buffer = nil then
    Exit;

  OldSelStart := ARichMemo.SelStart;
  OldSelLength := ARichMemo.SelLength;

  ARichMemo.SuspendUndo;
  try
    GtkBeginBatch(ARichMemo);
    try
      gtk_text_buffer_get_start_iter(Buffer, @StartIter);
      gtk_text_buffer_get_end_iter(Buffer, @EndIter);
      gtk_text_buffer_remove_all_tags(Buffer, @StartIter, @EndIter);
    finally
      if ARichMemo.SelStart <> OldSelStart then
        ARichMemo.SelStart := OldSelStart;
      if ARichMemo.SelLength <> OldSelLength then
        ARichMemo.SelLength := OldSelLength;
      GtkEndBatch(ARichMemo);
    end;
  finally
    ARichMemo.ResumeUndo;
  end;
  {$ENDIF}
  {$IFDEF LCLGTK3}
  // GTK3 exposes the same functions with the same signatures, so the body
  // is identical. Kept separate to make future platform specific tweaks
  // easy to add without touching the GTK2 branch.
  if not Assigned(ARichMemo) then
    Exit;

  Widget := PGtkWidget(ARichMemo.Handle);
  if Widget = nil then
    Exit;

  Buffer := gtk_text_view_get_buffer(GTK_TEXT_VIEW(Widget));
  if Buffer = nil then
    Exit;

  OldSelStart := ARichMemo.SelStart;
  OldSelLength := ARichMemo.SelLength;

  ARichMemo.SuspendUndo;
  try
    GtkBeginBatch(ARichMemo);
    try
      gtk_text_buffer_get_start_iter(Buffer, @StartIter);
      gtk_text_buffer_get_end_iter(Buffer, @EndIter);
      gtk_text_buffer_remove_all_tags(Buffer, @StartIter, @EndIter);
    finally
      if ARichMemo.SelStart <> OldSelStart then
        ARichMemo.SelStart := OldSelStart;
      if ARichMemo.SelLength <> OldSelLength then
        ARichMemo.SelLength := OldSelLength;
      GtkEndBatch(ARichMemo);
    end;
  finally
    ARichMemo.ResumeUndo;
  end;
  {$ENDIF}
end;

procedure ClearSpellErrors(ARichMemo: TRichMemo);
{$IFDEF WINDOWS}
var
  OldSelStart, OldSelLength: integer;
  cf: CHARFORMAT2W;
  cr: CHARRANGE;
  scrollPos: TPoint;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  if not Assigned(ARichMemo) then
    Exit;

  // Save caret and scroll positions
  OldSelStart := ARichMemo.SelStart;
  OldSelLength := ARichMemo.SelLength;
  {$HINTS OFF}
  SendMessage(ARichMemo.Handle, EM_GETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
  {$HINTS ON}

  ARichMemo.SuspendUndo;
  try
    SendMessage(ARichMemo.Handle, WM_SETREDRAW, 0, 0);
    try
      cr.cpMin := 0;
      cr.cpMax := Length(ARichMemo.Text);
      {$HINTS OFF}
      SendMessage(ARichMemo.Handle, EM_EXSETSEL, 0, LPARAM(PtrInt(@cr)));
      {$HINTS ON}

      cf := Default(CHARFORMAT2W);
      cf.cbSize := SizeOf(cf);
      cf.dwMask := CFM_UNDERLINE or CFM_UNDERLINETYPE or CFM_UNDERLINECOLOR or CFM_COLOR;
      cf.dwEffects := 0;
      cf.bUnderlineType := CFU_UNDERLINENONE;
      cf.bUnderlineColor := 0;
      cf.crTextColor := GetSysColor(COLOR_WINDOWTEXT);

      {$HINTS OFF}
      SendMessage(ARichMemo.Handle, EM_SETCHARFORMAT, SCF_SELECTION, LPARAM(PtrInt(@cf)));
      {$HINTS ON}
    finally
      ARichMemo.SelStart := OldSelStart;
      ARichMemo.SelLength := OldSelLength;
      {$HINTS OFF}
      SendMessage(ARichMemo.Handle, EM_SETSCROLLPOS, 0, LPARAM(PtrInt(@scrollPos)));
      {$HINTS ON}
      SendMessage(ARichMemo.Handle, WM_SETREDRAW, 1, 0);
      ARichMemo.Invalidate;
    end;
  finally
    ARichMemo.ResumeUndo;
  end;
  {$ELSE}
  if not Assigned(ARichMemo) then
    Exit;
  if Length(ARichMemo.Text) = 0 then
    Exit;

  // RemoveAllTagsNative owns batching (GtkBeginBatch/GtkEndBatch), undo
  // suspension and selection restore on GTK, so no additional wrapping
  // is needed here. Lines.BeginUpdate still collapses the widget level
  // layout pass into a single one.
  ARichMemo.Lines.BeginUpdate;
  try
    RemoveAllTagsNative(ARichMemo);
  finally
    ARichMemo.Lines.EndUpdate;
  end;
  {$ENDIF}
end;

{%EndRegion}

{%Region -fold TRichSpellChecker}

constructor TRichSpellChecker.Create(ARichMemo: TRichMemo);
begin
  inherited Create;
  FRichMemo := ARichMemo;
  FMenu := TPopupMenu.Create(nil);
  FErrors := TList.Create;
  FInjectedItems := TList.Create;
  FCurrentError := nil;
  FApplyImmediately := True;
  FContextCaretPos := -1;
  FUpdateLock := 0;
  FErrorsAtBeginUpdate := 0;
  FTargetPopupMenu := nil;
  FSubMenu := False;
  FSubMenuCaption := 'Suggestions';
  FSubMenuIndex := 0;
  FIsShowingOurMenu := False;
  FOriginalPopupOnPopup := nil;
  FOriginalPopupOnClose := nil;
  FMemoChangeOnReplace := False;

  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.Interval := 100; // 100 ms delay before cleanup
  FTimer.OnTimer := @TimerHandler;
end;

destructor TRichSpellChecker.Destroy;
begin
  // Stop timer and cleanup
  FTimer.Enabled := False;

  // Restore original event handlers if our popup is still attached
  if FIsShowingOurMenu and (FTargetPopupMenu <> nil) then
  begin
    FTargetPopupMenu.OnPopup := FOriginalPopupOnPopup;
    FTargetPopupMenu.OnClose := FOriginalPopupOnClose;
    FIsShowingOurMenu := False;
  end;

  ClearInjectedItems;
  FreeAndNil(FTimer);
  FreeAndNil(FInjectedItems);
  Clear;
  FreeAndNil(FMenu);
  FreeAndNil(FErrors);
  inherited Destroy;
end;

procedure TRichSpellChecker.Clear;
var
  i: integer = 0;
  p: PSpellError = nil;
begin
  // Clear the drawn underlines before releasing the error records. The
  // order does not matter functionally, but freeing the pointers first
  // would leave the memo holding stale underline ranges in case the
  // clear path is ever changed to inspect FErrors.
  ClearUnderlines;

  for i := FErrors.Count - 1 downto 0 do
  begin
    p := PSpellError(FErrors[i]);
    if Assigned(p) then
    begin
      // Replacements is now a managed dynamic array, no manual Free needed
      Dispose(p);
    end;
    FErrors.Delete(i);
  end;
  FCurrentError := nil;
  // Reset the incremental draw marker. Any errors added after this point
  // must be treated as new, because the visual underlines were just wiped.
  FErrorsAtBeginUpdate := 0;
end;

procedure TRichSpellChecker.BeginUpdate;
begin
  if FUpdateLock = 0 then
  begin
    FMenu.Close; // close context menu if it is open
    // Remember how many errors already exist. EndUpdate will only redraw
    // the errors that are added after this point, keeping incremental
    // spell checking linear instead of quadratic.
    FErrorsAtBeginUpdate := FErrors.Count;
  end;
  Inc(FUpdateLock);
  FApplyImmediately := False;
end;

procedure TRichSpellChecker.EndUpdate;
begin
  Dec(FUpdateLock);
  if FUpdateLock < 0 then
    FUpdateLock := 0; // safety guard against unbalanced calls
  FApplyImmediately := True;
  // Redraw only errors added since the outermost BeginUpdate. A full
  // ApplyUnderlines would touch every accumulated error on every chunk,
  // turning the total work into O(N^2) for large documents.
  ApplyUnderlinesFrom(FErrorsAtBeginUpdate);
end;

procedure TRichSpellChecker.ClearUnderlines;
begin
  ClearSpellErrors(FRichMemo);
end;

procedure TRichSpellChecker.AddError(AOffset, ALength: integer; const AMessage: string; const AReplacements: array of string;
  AColor: TColor = clRed);
var
  err: PSpellError;
  i: integer;
begin
  New(err);
  err^.Offset := AOffset;
  err^.Length := ALength;
  err^.Message := AMessage;
  err^.Color := AColor;
  // Copy replacements from open array to dynamic array
  SetLength(err^.Replacements, Length(AReplacements));
  for i := Low(AReplacements) to High(AReplacements) do
    err^.Replacements[i] := AReplacements[i];

  FErrors.Add(err);
  if FApplyImmediately then
    ApplyUnderlineToError(err);
end;

procedure TRichSpellChecker.ApplyUnderlineToError(AError: PSpellError);
begin
  if AError = nil then
    Exit;
  DrawSpellUnderline(FRichMemo, AError^.Offset, AError^.Length, AError^.Color);
end;

procedure TRichSpellChecker.ApplyUnderlines;
begin
  DrawSpellErrorsBatch(FRichMemo, FErrors);
end;

procedure TRichSpellChecker.ApplyUnderlinesFrom(AStartIndex: integer);
begin
  DrawSpellErrorsBatch(FRichMemo, FErrors, AStartIndex);
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
  {$IFDEF WINDOWS}
var
  Pt: TPoint;
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
  Result := -1;
  if not Assigned(FRichMemo) then Exit;

  Result := FRichMemo.CharAtPos(X, Y);
  {$ENDIF}
end;

procedure TRichSpellChecker.ClearInjectedItems;
var
  i: integer;
  Item: TMenuItem;
begin
  for i := FInjectedItems.Count - 1 downto 0 do
  begin
    Item := TMenuItem(FInjectedItems[i]);
    // Remove from its parent (if any)
    if Assigned(Item.Parent) then
      Item.Parent.Remove(Item)
    else if Assigned(Item.Menu) then
      Item.Menu.Items.Remove(Item);
    // Free the item and its children (if any)
    Item.Free;
  end;
  FInjectedItems.Clear;
end;

procedure TRichSpellChecker.SetTargetPopupMenu(const AValue: TPopupMenu);
begin
  if FTargetPopupMenu <> AValue then
  begin
    // Stop pending cleanup timer
    FTimer.Enabled := False;

    // Restore original handlers if attached to the old menu
    if FIsShowingOurMenu and (FTargetPopupMenu <> nil) then
    begin
      FTargetPopupMenu.OnPopup := FOriginalPopupOnPopup;
      FTargetPopupMenu.OnClose := FOriginalPopupOnClose;
      FIsShowingOurMenu := False;
    end;

    ClearInjectedItems;
    FTargetPopupMenu := AValue;
    FOriginalPopupOnPopup := nil;
    FOriginalPopupOnClose := nil;
    FIsShowingOurMenu := False;
  end;
end;

procedure TRichSpellChecker.PopupCloseHandler(Sender: TObject);
begin
  if FIsShowingOurMenu then
  begin
    FIsShowingOurMenu := False;
    // Restore original handlers
    FTargetPopupMenu.OnPopup := FOriginalPopupOnPopup;
    FTargetPopupMenu.OnClose := FOriginalPopupOnClose;
    FOriginalPopupOnPopup := nil;
    FOriginalPopupOnClose := nil;
    // Start delayed cleanup to allow OnClick of menu items to process
    FTimer.Enabled := False;
    FTimer.Enabled := True;
    // Call the original OnClose handler if it was assigned
    if Assigned(FTargetPopupMenu.OnClose) then
      FTargetPopupMenu.OnClose(Sender);
  end;
end;

procedure TRichSpellChecker.TimerHandler(Sender: TObject);
begin
  FTimer.Enabled := False;
  ClearInjectedItems;
end;

function TRichSpellChecker.ShowContextMenu(X, Y: integer): boolean;
var
  CharIndex: integer;
  Error: PSpellError;
  Item: TMenuItem;
  i: integer;
  ScreenPoint: TPoint;
  InsertIndex: integer;
  SMenu: TMenuItem;
begin
  Result := False;
  if not Assigned(FRichMemo) then
    Exit;

  if FUpdateLock > 0 then
    Exit; // do not show menu while updates are in progress

  CharIndex := GetCharIndexAtPos(X, Y);
  if CharIndex < 0 then
    Exit;

  Error := GetErrorAtTextPos(CharIndex);
  if Error = nil then
    Exit;

  FCurrentError := Error;
  // Save caret position for later restore after replacement
  FContextCaretPos := FRichMemo.SelStart;

  // Convert client coordinates to screen coordinates for Popup
  ScreenPoint := FRichMemo.ClientToScreen(Types.Point(X, Y));

  // If external popup menu is set, insert items there
  if FTargetPopupMenu <> nil then
  begin
    // Ensure any pending cleanup is done before adding new items
    FTimer.Enabled := False;
    ClearInjectedItems;

    // Determine insertion index
    InsertIndex := FSubMenuIndex;
    if (InsertIndex < 0) or (InsertIndex > FTargetPopupMenu.Items.Count) then
      InsertIndex := FTargetPopupMenu.Items.Count; // append to end if out of range

    if FSubMenu then
    begin
      // Create SMenu with caption
      SMenu := TMenuItem.Create(FTargetPopupMenu);
      SMenu.Caption := FSubMenuCaption;
      // Add replacement items to SMenu
      for i := 0 to High(Error^.Replacements) do
      begin
        Item := TMenuItem.Create(SMenu);
        Item.Caption := Error^.Replacements[i];
        Item.OnClick := @ReplacementClick;
        SMenu.Add(Item);
      end;
      // Insert SMenu at specified index
      FTargetPopupMenu.Items.Insert(InsertIndex, SMenu);
      // Remember only the SMenu root for cleanup (children are freed automatically)
      FInjectedItems.Add(SMenu);
    end
    else
    begin
      // Insert replacement items directly at root
      for i := 0 to High(Error^.Replacements) do
      begin
        Item := TMenuItem.Create(FTargetPopupMenu);
        Item.Caption := Error^.Replacements[i];
        Item.OnClick := @ReplacementClick;
        FTargetPopupMenu.Items.Insert(InsertIndex + i, Item);
        FInjectedItems.Add(Item);
      end;
      // Add a separator after the items
      Item := TMenuItem.Create(FTargetPopupMenu);
      Item.Caption := '-';
      FTargetPopupMenu.Items.Insert(InsertIndex + High(Error^.Replacements) + 1, Item);
      FInjectedItems.Add(Item);
    end;

    // Save original event handlers and assign ours to manage cleanup timing
    FOriginalPopupOnPopup := FTargetPopupMenu.OnPopup;
    FOriginalPopupOnClose := FTargetPopupMenu.OnClose;
    FTargetPopupMenu.OnPopup := nil; // we don't need OnPopup for cleanup now
    FTargetPopupMenu.OnClose := @PopupCloseHandler;
    FIsShowingOurMenu := True;

    // Show the external popup menu
    FTargetPopupMenu.Popup(ScreenPoint.X, ScreenPoint.Y);
    Result := True;
  end
  else
  begin
    // Use own internal popup menu (default behavior)
    FMenu.Items.Clear;
    for i := 0 to High(Error^.Replacements) do
    begin
      Item := TMenuItem.Create(FMenu);
      Item.Caption := Error^.Replacements[i];
      Item.OnClick := @ReplacementClick;
      FMenu.Items.Add(Item);
    end;
    if FMenu.Items.Count > 0 then
    begin
      FMenu.Popup(ScreenPoint.X, ScreenPoint.Y);
      Result := True;
    end;
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
  OldOnChange: TNotifyEvent;
  SuppressOnChange: boolean;
begin
  if FCurrentError = nil then
    Exit;

  // If read-only mode, we don't do replacement
  if not Assigned(FRichMemo) or FRichMemo.ReadOnly then
  begin
    FContextCaretPos := -1;
    FCurrentError := nil;
    Exit;
  end;

  // Temporarily disable OnChange event to prevent reentrant spell checking,
  // unless the caller asked to keep it active via MemoChangeOnReplace.
  SuppressOnChange := not FMemoChangeOnReplace;
  OldOnChange := nil;
  if SuppressOnChange then
  begin
    OldOnChange := FRichMemo.OnChange;
    FRichMemo.OnChange := nil;
  end;
  try

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
  finally
    // Restore original OnChange handler only if we cleared it
    if SuppressOnChange then
      FRichMemo.OnChange := OldOnChange;
  end;
end;

procedure TRichSpellChecker.ReplaceError(AError: PSpellError; const ANewText: string; NewCaretPos: integer);
begin
  if not Assigned(FRichMemo) or (AError = nil) or FRichMemo.ReadOnly then
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
{$IFDEF WINDOWS}
var
  OldSelStart, OldSelLength: integer;
  scrollPos: TPoint;
  cf: CHARFORMAT2W;
  cr: CHARRANGE;
{$ELSE}
var
  OldSelStart, OldSelLength: integer;
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
  FRichMemo.SuspendUndo;
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
    cf.dwMask := CFM_UNDERLINE or CFM_UNDERLINETYPE or CFM_UNDERLINECOLOR or CFM_COLOR;
    cf.dwEffects := 0;
    cf.bUnderlineType := CFU_UNDERLINENONE;
    cf.bUnderlineColor := 0;
    cf.crTextColor := GetSysColor(COLOR_WINDOWTEXT);

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
    FRichMemo.ResumeUndo;
  end;
  {$ELSE}
  if not Assigned(FRichMemo) or (AError = nil) then
    Exit;

  // On GTK and macOS, replace the whole range with an unstyled one. Save
  // and restore the selection only when it actually changed, otherwise the
  // widget would scroll the caret back into view on every call.
  // GtkBeginBatch/GtkEndBatch keep the change and the surrounding selection
  // restore inside a single user action, so the widget redraws once.
  // Removing a single underline is service formatting and must not be
  // recorded in the undo tracker, so suppress undo for the operation.
  OldSelStart := FRichMemo.SelStart;
  OldSelLength := FRichMemo.SelLength;
  FRichMemo.SuspendUndo;
  try
    GtkBeginBatch(FRichMemo);
    try
      FRichMemo.Lines.BeginUpdate;
      try
        FRichMemo.SetRangeParams(
          AError^.Offset,
          ANewLength,
          [tmm_Styles, tmm_Color],
          '',
          0,
          clWindowText,
          [],
          []
          );
      finally
        if FRichMemo.SelStart <> OldSelStart then
          FRichMemo.SelStart := OldSelStart;
        if FRichMemo.SelLength <> OldSelLength then
          FRichMemo.SelLength := OldSelLength;
        FRichMemo.Lines.EndUpdate;
      end;
    finally
      GtkEndBatch(FRichMemo);
    end;
  finally
    FRichMemo.ResumeUndo;
  end;
  {$ENDIF}

  // Remove error from list
  FErrors.Remove(AError);
  // Replacements is now a managed dynamic array, no manual Free needed
  Dispose(AError);
end;

procedure TRichSpellChecker.UpdateErrorSuggestions(AOffset, ALength: integer; const AReplacements: array of string);
var
  i, j: integer;
  err: PSpellError;
begin
  for i := 0 to FErrors.Count - 1 do
  begin
    err := PSpellError(FErrors[i]);
    if (err^.Offset = AOffset) and (err^.Length = ALength) then
    begin
      SetLength(err^.Replacements, Length(AReplacements));
      for j := Low(AReplacements) to High(AReplacements) do
        err^.Replacements[j] := AReplacements[j];
      Exit;
    end;
  end;
end;

{%EndRegion}

end.
