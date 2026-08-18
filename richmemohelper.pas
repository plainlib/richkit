unit RichMemoHelper;

{$mode objfpc}{$H+}

interface

uses
  RichMemo, RichMemoHelpers, StrUtils;

type
  TRichMemoClipboardHelper = class helper(TRichEditForMemo) for TRichMemo
  public
    // Paste HTML content from clipboard as RTF at cursor position
    function PasteFromClipboardEx(AUseHtmlFormat: boolean = True): boolean;

    // Copy selected content to clipboard in plain text, RTF and HTML formats
    function CopyToClipboardEx: boolean;

    // Cut selected content to clipboard in plain text, RTF and HTML formats
    function CutToClipboardEx: boolean;

    // Detects whether the document contains rich text formatting
    function HasRichFormatting: boolean;
  end;

implementation

uses
  Classes, SysUtils, Clipbrd, HtmlToRtf, RtfToHtml, ClipToHtml, clipboardhelper, stringhelper, controlshelper;

var
  CF_RTF_FORMAT: QWord = 0;

const
  FormattingCommands: array[0..17] of string = (
    '\b', '\i', '\ul', '\cf', '\highlight',
    '\ql', '\qc', '\qj', '\li', '\ri', '\sa', '\sb', '\sl', '\tx',
    '\strike', '\sub', '\super', '\caps');

procedure EnsureRtfFormatRegistered;
begin
  if CF_RTF_FORMAT = 0 then
    CF_RTF_FORMAT := RegisterClipboardFormat('Rich Text Format');
end;

function TRichMemoClipboardHelper.PasteFromClipboardEx(AUseHtmlFormat: boolean = True): boolean;
  {$IFDEF WINDOWS}
var
  HtmlText: string = '';
  RtfText: string = '';
  TempStream: TMemoryStream = nil;
  SavedFormats: TClipboardFormatDataArray = nil;
  {$ENDIF}
begin
  Result := False;

  {$IFDEF WINDOWS}
  if AUseHtmlFormat then
    HtmlText := GetHtmlFromClipboard
  else
    HtmlText := Clipboard.AsText;

  if HtmlText = '' then
    Exit;

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
  {$ENDIF}
end;

function TRichMemoClipboardHelper.CopyToClipboardEx: boolean;
var
  RtfText: string = '';
  HtmlText: string = '';
  PlainText: string = '';
  ms: TMemoryStream = nil;
begin
  Result := False;

  {$IFDEF WINDOWS}
  if Self.SelLength = 0 then Exit;

  EnsureRtfFormatRegistered;
  EnsureClipboardFormatsRegistered;

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

function TRichMemoClipboardHelper.CutToClipboardEx: boolean;
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

function TRichMemoClipboardHelper.HasRichFormatting: boolean;
var
  rtfText: string = '';
  plainText: string = '';
  i: integer = 0;
  searchPos: integer = 0;
  foundPos: integer = 0;
  cmd: string = '';
  fsValue: integer = 0;
  digitStart: integer = 0;
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
          Result := True;
          Exit;
        end;
        searchPos := foundPos + 1;
      end;
    until foundPos = 0;
  end;

  // Check for font size changes: parse \fsN and compare with default 18
  searchPos := 1;
  repeat
    foundPos := PosEx('\fs', rtfText, searchPos);
    if foundPos > 0 then
    begin
      if not rtfText.IsEscapedBackslash(foundPos) then
      begin
        digitStart := foundPos + 3; // Skip "\fs"
        fsValue := 0;
        while (digitStart <= Length(rtfText)) and (rtfText[digitStart] in ['0'..'9']) do
        begin
          fsValue := fsValue * 10 + Ord(rtfText[digitStart]) - Ord('0');
          Inc(digitStart);
        end;
        if fsValue <> 18 then
        begin
          Result := True;
          Exit;
        end;
      end;
      searchPos := foundPos + 1;
    end;
  until foundPos = 0;
end;

end.
