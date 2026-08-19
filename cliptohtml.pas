unit ClipToHtml;

{$mode objfpc}{$H+}

interface

uses
  Clipbrd;

var
  CF_HTML_FORMAT: QWord = 0;
  CF_TEXT_HTML_FORMAT: QWord = 0;
  CF_PUBLIC_HTML_FORMAT: QWord = 0;
  CF_RTF_FORMAT: QWord = 0;

// Ensures that the known HTML clipboard formats are registered
procedure EnsureHtmlFormatRegistered;

// Ensures that the Rtf clipboard format are registered
procedure EnsureRtfFormatRegistered;

// Returns the HTML content from the clipboard as a string.
// Tries several known HTML formats across platforms.
function GetHtmlFromClipboard: string;

implementation

uses
  Classes, SysUtils;

procedure EnsureHtmlFormatRegistered;
begin
  if CF_HTML_FORMAT = 0 then
    CF_HTML_FORMAT := RegisterClipboardFormat('HTML Format');
  if CF_TEXT_HTML_FORMAT = 0 then
    CF_TEXT_HTML_FORMAT := RegisterClipboardFormat('text/html');
  if CF_PUBLIC_HTML_FORMAT = 0 then
    CF_PUBLIC_HTML_FORMAT := RegisterClipboardFormat('public.html');
end;

procedure EnsureRtfFormatRegistered;
begin
  if CF_RTF_FORMAT = 0 then
    CF_RTF_FORMAT := RegisterClipboardFormat('Rich Text Format');
end;

function ExtractHtmlBody(const AClipboardHtml: string): string;
var
  lower: string = '';
  startPos, endPos: integer;
begin
  Result := AClipboardHtml;

  lower := LowerCase(Result);
  startPos := Pos('<html', lower);
  if startPos = 0 then
    startPos := Pos('<body', lower);

  if startPos > 0 then
    Result := Copy(Result, startPos, Length(Result) - startPos + 1);

  lower := LowerCase(Result);
  endPos := Pos('</html>', lower);
  if endPos > 0 then
    Result := Copy(Result, 1, endPos + Length('</html>') - 1);
end;

function GetHtmlFromClipboard: string;
var
  ms: TMemoryStream = nil;
  s: string = '';
  formatID: QWord = 0;
begin
  Result := '';
  EnsureHtmlFormatRegistered;

  formatID := 0;

  if (CF_TEXT_HTML_FORMAT <> 0) and Clipboard.HasFormat(CF_TEXT_HTML_FORMAT) then
    formatID := CF_TEXT_HTML_FORMAT
  else if (CF_HTML_FORMAT <> 0) and Clipboard.HasFormat(CF_HTML_FORMAT) then
    formatID := CF_HTML_FORMAT
  else if (CF_PUBLIC_HTML_FORMAT <> 0) and Clipboard.HasFormat(CF_PUBLIC_HTML_FORMAT) then
    formatID := CF_PUBLIC_HTML_FORMAT;

  if formatID = 0 then Exit;

  ms := TMemoryStream.Create;
  try
    if Clipboard.GetFormat(formatID, ms) then
    begin
      ms.Position := 0;
      SetLength(s, ms.Size);
      if ms.Size > 0 then
        ms.ReadBuffer(s[1], ms.Size);
      Result := s;
    end;
  finally
    ms.Free;
  end;

  if Result <> '' then
    Result := ExtractHtmlBody(Result);
end;

end.
