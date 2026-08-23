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
  {$IFDEF WINDOWS}
  Windows,
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
    // Paste HTML content from clipboard as RTF at cursor position
    function PasteFromClipboardEx(AUseHtmlFormat: boolean = True): boolean;

    // Copy selected content to clipboard in plain text, RTF and HTML formats
    function CopyToClipboardEx: boolean;

    // Cut selected content to clipboard in plain text, RTF and HTML formats
    function CutToClipboardEx: boolean;

    // Detects whether the document contains rich text formatting
    function HasRichFormatting: boolean;

    // Inserts the given RTF fragment at the current cursor position.
    // The fragment should be raw RTF content (e.g., '{\b bold}') without
    // the outer document braces and header.
    procedure InsertRtfAtCursor(const ARtf: string);

    // Inserts clipboard text, normalizing all line endings to LineEnding.
    procedure PasteWithLineEnding;

    // Set text bidi mode
    procedure ApplyBidiMode;

    // Get full text height
    function GetTextHeight: integer;

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
  end;

implementation

uses
  HtmlToRtf,
  {$IFDEF WINDOWS}
  RtfToHtml,
  clipboardhelper,
  {$ENDIF}
  ClipToHtml,
  stringhelper,
  controlshelper;

{$IFDEF WINDOWS}

const
  SCROLLBAR_FIX_TIMER_ID = 1;
  SCROLLBAR_FIX_INTERVAL = 30;
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

  // Keep compositing disabled only while dragging a scrollbar
  NeedComposited :=
    not (OverScrollbar and
         ((GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0));

  ExStyle := GetWindowLongPtr(ParentPanel.Handle, GWL_EXSTYLE);
  CurrentComposited := (ExStyle and WS_EX_COMPOSITED) <> 0;

  if CurrentComposited <> NeedComposited then
    ParentPanel.SetComposited(NeedComposited);
end;

{$ENDIF}

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
  if ARtf = '' then
    Exit;

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

  if HtmlText = '' then
    Exit;

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

    // Standard paste inserts at the current cursor position
    Self.PasteFromClipboard;
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
        Clipboard.AddFormat(CF_TEXT, ms);
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
end;

function TRichMemoHelper.CutToClipboardEx: boolean;
begin
  Result := False;

  {$IFDEF WINDOWS}
  if Self.SelLength = 0 then Exit;

  // Copy selected content to clipboard
  if not Self.CopyToClipboardEx then Exit;

  // Delete the selected text
  Self.SelText := '';
  Result := True;
  {$ENDIF}
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

procedure TRichMemoHelper.PasteWithLineEnding;
var
  s: string;
begin
  if Clipboard.HasFormat(CF_TEXT) then
  begin
    s := Clipboard.AsText;

    s := StringReplace(s, #13#10, #10, [rfReplaceAll]); // Windows CRLF -> LF
    s := StringReplace(s, #13, #10, [rfReplaceAll]);   // Macintosh CR -> LF
    s := StringReplace(s, #10, LineEnding, [rfReplaceAll]); // LF -> platform line ending

    Self.SelText := s;
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

function TRichMemoHelper.GetTextHeight: integer;
var
  Bmp: Graphics.TBitmap;
  TextRect: TRect;
  Txt: string;
  Flags: cardinal;
  LogicalWidth: integer; // Logical width for DrawText
begin
  Txt := Self.Text;

  if Txt = '' then
    Exit(0);

  // Always add LineEnding
  Txt := Txt + LineEnding + ' ';
  //if (Length(Txt) > 0) and (Txt[Length(Txt)] in [#10, #13]) then
  //  Txt := Txt + ' ';

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
      PChar(Txt),
      Length(Txt),
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

function TRichMemoHelper.GetBottomSpace: integer;
begin
  if Self.Text = '' then
  begin
    Result := Self.ClientHeight;
    Exit;
  end;

  // Free space = visible height - actual text height
  Result := Self.ClientHeight - Self.GetTextHeight;

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

end.
