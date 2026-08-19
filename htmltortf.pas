//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit HtmlToRtf;

{$mode objfpc}{$H+}

interface

// Convert HTML string to RTF.
// If AsFragment is True, returns only RTF content without header/footer.
// If UseInlineFormatting is True, inline formatting tags (b, i, u, strike)
// are emitted as RTF control words instead of groups.
function ConvertHtmlToRtf(const Html: string; DefaultFontSizePt: integer; AsFragment: boolean = False;
  UseInlineFormatting: boolean = False): string;

implementation

uses
  SysUtils, Classes, StrUtils, LazUTF8;

const
  MaxListLevel = 9; // Maximum nesting level for lists

type
  TFormatState = record
    Bold: integer;
    Italic: integer;
    Underline: integer;
    Code: integer;
    Pre: integer;
    Link: integer;
    LinkUrl: string;
    Strike: integer; // Strikethrough level
    FontIndex: integer; // Index of current font in FFontTable
    FontSize: integer; // Font size in half-points, 0 means default
  end;

  TListInfo = record
    ListType: string; // 'ul' or 'ol'
    Counter: integer;
  end;

  THtmlParser = class
  private
    FHtml: string;
    FPos: integer;
    FResult: string;
    FFormat: TFormatState;
    FFontTable: TStringList; // Font names used in RTF
    FListStack: array[0..MaxListLevel] of TListInfo;
    FListLevel: integer;
    FInTag: boolean;
    FInComment: boolean;
    FInSkipTag: string;
    FSkipDepth: integer;
    FTagContent: string;
    FTextBuffer: string;
    FLastWasBlock: boolean;
    FPendingSpace: boolean;
    FDefaultFontSize: integer; // Default font size in half-points (pt * 2)
    FAsFragment: boolean; // If True, output only RTF body without wrapping
    FUseInlineFormatting: boolean; // If True, inline formatting uses control words
    procedure Parse;
    procedure ProcessText(const S: string);
    procedure FlushTextBuffer;
    procedure ProcessTag(const Tag: string);
    procedure AddText(const AText: string; Format: TFormatState);
    function EscapeRTF(const S: string; PreMode: boolean): string;
    function EscapeAsciiRTF(const S: string): string;
    function EscapeUnicode(const S: string): string;
    function DecodeEntities(const S: string): string;
    procedure AddParIfNeeded;
    function IsOnlySpaces(const S: string): boolean;
    function NormalizeSpaces(const S: string): string;
    function ExtractAttribute(const Tag, Attr: string): string;
    function ExtractFontFamily(const Style: string): string;
    procedure ProcessOpeningTag(const Name, AttrString: string);
    procedure ProcessClosingTag(const Name: string);
    procedure IncreaseListLevel(const ListType: string; StartValue: integer);
    procedure DecreaseListLevel;
    procedure AddListItemMarker;
    function ExtractFontSize(const Style: string): integer;
  public
    constructor Create(const Html: string; ADefaultFontSizePt: integer; AAsFragment: boolean; AUseInlineFormatting: boolean);
    destructor Destroy; override;
    function Convert: string;
  end;

constructor THtmlParser.Create(const Html: string; ADefaultFontSizePt: integer; AAsFragment: boolean; AUseInlineFormatting: boolean);
var
  i: integer;
begin
  inherited Create;
  FHtml := Html;
  FDefaultFontSize := ADefaultFontSizePt * 2;
  FPos := 1;
  FResult := '';
  FFormat.Bold := 0;
  FFormat.Italic := 0;
  FFormat.Underline := 0;
  FFormat.Code := 0;
  FFormat.Pre := 0;
  FFormat.Link := 0;
  FFormat.LinkUrl := '';
  FFormat.Strike := 0;
  FFormat.FontIndex := 0; // default Arial
  FFormat.FontSize := 0; // Default size, will use RTF default
  FAsFragment := AAsFragment;
  FUseInlineFormatting := AUseInlineFormatting;
  FFontTable := TStringList.Create;
  FFontTable.Add('Arial');      // index 0
  FFontTable.Add('Courier New'); // index 1
  FListLevel := 0;
  for i := 0 to MaxListLevel do
  begin
    FListStack[i].ListType := '';
    FListStack[i].Counter := 0;
  end;
  FInTag := False;
  FInComment := False;
  FInSkipTag := '';
  FSkipDepth := 0;
  FTagContent := '';
  FTextBuffer := '';
  FLastWasBlock := False;
  FPendingSpace := False;
end;

destructor THtmlParser.Destroy;
begin
  FFontTable.Free;
  inherited Destroy;
end;

function THtmlParser.Convert: string;
var
  FontTbl: string;
  i: integer;
begin
  Parse;
  if FAsFragment then
  begin
    // Return only RTF body without wrapper and font table
    Result := FResult;
    Exit;
  end;
  // Build font table from used fonts
  FontTbl := '';
  for i := 0 to FFontTable.Count - 1 do
  begin
    if Trim(FFontTable[i]) = '' then
      FFontTable[i] := 'Arial'; // fallback to avoid empty font name
    FontTbl := FontTbl + '{\f' + IntToStr(i) + '\fnil\fcharset0 ' + FFontTable[i] + ';}';
  end;
  Result := '{\rtf1\ansi\ansicpg1251\deff0' + '{\fonttbl' + FontTbl + '}' + '{\colortbl ;\red0\green0\blue255;}' +
    '\fs' + IntToStr(FDefaultFontSize) + ' ' + FResult + '}';
end;

procedure THtmlParser.Parse;
var
  ch: char;
  len: integer;
begin
  while FPos <= Length(FHtml) do
  begin
    ch := FHtml[FPos];
    if FInSkipTag <> '' then
    begin
      len := Length(FInSkipTag);
      if (FPos + len <= Length(FHtml)) and (LowerCase(Copy(FHtml, FPos, len)) = FInSkipTag) then
      begin
        FSkipDepth := 0;
        FInSkipTag := '';
        Inc(FPos, len);
        Continue;
      end;
      Inc(FPos);
      Continue;
    end;

    if FInComment then
    begin
      if (FPos + 2 <= Length(FHtml)) and (Copy(FHtml, FPos, 3) = '-->') then
      begin
        FInComment := False;
        Inc(FPos, 3);
      end
      else
        Inc(FPos);
      Continue;
    end;

    if FInTag then
    begin
      if ch = '>' then
      begin
        ProcessTag(FTagContent);
        FTagContent := '';
        FInTag := False;
        Inc(FPos);
        Continue;
      end
      else if ch = '"' then
      begin
        FTagContent := FTagContent + ch;
        Inc(FPos);
        while (FPos <= Length(FHtml)) and (FHtml[FPos] <> '"') do
        begin
          FTagContent := FTagContent + FHtml[FPos];
          Inc(FPos);
        end;
        if FPos <= Length(FHtml) then
        begin
          FTagContent := FTagContent + '"';
          Inc(FPos);
        end;
        Continue;
      end
      else
      begin
        FTagContent := FTagContent + ch;
        Inc(FPos);
        Continue;
      end;
    end;

    // Not inside tag or comment
    if ch = '<' then
    begin
      if (FPos + 3 <= Length(FHtml)) and (Copy(FHtml, FPos, 4) = '<!--') then
      begin
        FlushTextBuffer;
        FInComment := True;
        Inc(FPos, 4);
        Continue;
      end;

      FlushTextBuffer;
      FInTag := True;
      FTagContent := '';
      Inc(FPos);
      Continue;
    end;

    FTextBuffer := FTextBuffer + ch;
    Inc(FPos);
  end;

  FlushTextBuffer;
end;

procedure THtmlParser.FlushTextBuffer;
begin
  if FTextBuffer <> '' then
  begin
    ProcessText(FTextBuffer);
    FTextBuffer := '';
  end;
end;

procedure THtmlParser.ProcessText(const S: string);
var
  Decoded: string;
  Normalized: string;
  HasLeadingSpace: boolean;
  HasTrailingSpace: boolean;
  Line: string;
  k: integer;
begin
  Decoded := DecodeEntities(S);

  if FFormat.Pre > 0 then
  begin
    // In pre, preserve line breaks and spaces exactly
    Decoded := StringReplace(Decoded, #13#10, #10, [rfReplaceAll]);
    Decoded := StringReplace(Decoded, #13, #10, [rfReplaceAll]);

    Line := '';
    for k := 1 to Length(Decoded) do
    begin
      if Decoded[k] = #10 then
      begin
        if Line <> '' then
          AddText(Line, FFormat);
        FResult := FResult + '\par ';
        Line := '';
      end
      else
        Line := Line + Decoded[k];
    end;
    if Line <> '' then
      AddText(Line, FFormat);

    FPendingSpace := False;
    FLastWasBlock := False;
  end
  else
  begin
    HasLeadingSpace := (Decoded <> '') and (Decoded[1] in [' ', #9, #10, #13, #12]);
    HasTrailingSpace := (Decoded <> '') and (Decoded[Length(Decoded)] in [' ', #9, #10, #13, #12]);

    if IsOnlySpaces(Decoded) then
    begin
      if not FLastWasBlock then
        FPendingSpace := True;
      Exit;
    end;

    Normalized := NormalizeSpaces(Decoded);

    if Normalized <> '' then
    begin
      if (FPendingSpace or HasLeadingSpace) and (not FLastWasBlock) then
        Normalized := ' ' + Normalized;

      AddText(Normalized, FFormat);
      FPendingSpace := HasTrailingSpace;
      FLastWasBlock := False;
    end
    else
    begin
      FPendingSpace := HasTrailingSpace;
    end;
  end;
end;

function THtmlParser.IsOnlySpaces(const S: string): boolean;
var
  i: integer;
begin
  Result := True;
  for i := 1 to Length(S) do
    if not (S[i] in [' ', #9, #10, #13, #12]) then
    begin
      Result := False;
      Exit;
    end;
end;

function THtmlParser.NormalizeSpaces(const S: string): string;
var
  i: integer;
  inSpace: boolean;
  ch: char;
begin
  Result := '';
  inSpace := False;
  for i := 1 to Length(S) do
  begin
    ch := S[i];
    if (ch = ' ') or (ch = #9) or (ch = #10) or (ch = #13) or (ch = #12) then
    begin
      if not inSpace then
      begin
        if Result <> '' then
          Result := Result + ' ';
        inSpace := True;
      end;
    end
    else
    begin
      Result := Result + ch;
      inSpace := False;
    end;
  end;
  Result := Trim(Result);
end;

procedure THtmlParser.AddText(const AText: string; Format: TFormatState);
var
  Escaped: string;
  fmtPrefix: string;
begin
  Escaped := EscapeRTF(AText, Format.Pre > 0);

  // Build a single formatting prefix group.
  // Inline formatting commands are not added here if UseInlineFormatting is active.
  fmtPrefix := '';
  if Format.FontIndex > 0 then
    fmtPrefix := fmtPrefix + '\f' + IntToStr(Format.FontIndex) + ' ';
  if Format.Code > 0 then
    fmtPrefix := fmtPrefix + '\f1 ';
  if Format.FontSize > 0 then
    fmtPrefix := fmtPrefix + '\fs' + IntToStr(Format.FontSize) + ' ';

  if not FUseInlineFormatting then
  begin
    if Format.Bold > 0 then
      fmtPrefix := fmtPrefix + '\b ';
    if Format.Italic > 0 then
      fmtPrefix := fmtPrefix + '\i ';
    if Format.Underline > 0 then
      fmtPrefix := fmtPrefix + '\ul ';
    if Format.Strike > 0 then
      fmtPrefix := fmtPrefix + '\strike ';
  end;

  if Format.Link > 0 then
    fmtPrefix := fmtPrefix + '\ul\cf1 '; // Link styling, kept as group

  if fmtPrefix <> '' then
    Escaped := '{' + fmtPrefix + ' ' + Escaped + '}';

  FResult := FResult + Escaped;
end;

function THtmlParser.EscapeUnicode(const S: string): string;
begin
  Result := EscapeRTF(S, False);
end;

function THtmlParser.EscapeAsciiRTF(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '{', '\{', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '\}', [rfReplaceAll]);
end;

function THtmlParser.EscapeRTF(const S: string; PreMode: boolean): string;
var
  i: integer;
  ch: char;
  asciiPart: string;
  cp: integer;
  len: integer;
begin
  Result := '';
  asciiPart := '';
  i := 1;
  while i <= Length(S) do
  begin
    ch := S[i];
    if Ord(ch) < 128 then
    begin
      asciiPart := asciiPart + ch;
      Inc(i);
    end
    else
    begin
      if asciiPart <> '' then
      begin
        Result := Result + EscapeAsciiRTF(asciiPart);
        asciiPart := '';
      end;
      {$NOTES OFF}
      len := UTF8CodepointSize(@S[i]);
      {$NOTES ON}
      if len = 0 then len := 1;
      cp := UTF8CodepointToUnicode(@S[i], len);
      Result := Result + '\u' + IntToStr(cp) + '?';
      Inc(i, len);
    end;
  end;
  if asciiPart <> '' then
    Result := Result + EscapeAsciiRTF(asciiPart);
end;

function THtmlParser.DecodeEntities(const S: string): string;
var
  i, j: integer;
  entity: string;
  numStr: string;
  codePoint: integer;
  outStr: string;
begin
  outStr := '';
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '&' then
    begin
      j := PosEx(';', S, i);
      if j > 0 then
      begin
        entity := LowerCase(Copy(S, i, j - i + 1));
        if entity = '&nbsp;' then
          outStr := outStr + ' '
        else if entity = '&amp;' then
          outStr := outStr + '&'
        else if entity = '&lt;' then
          outStr := outStr + '<'
        else if entity = '&gt;' then
          outStr := outStr + '>'
        else if entity = '&quot;' then
          outStr := outStr + '"'
        else if entity = '&apos;' then
          outStr := outStr + ''''
        else if entity = '&copy;' then
          outStr := outStr + '©'
        else if entity = '&reg;' then
          outStr := outStr + '®'
        else if entity = '&trade;' then
          outStr := outStr + '™'
        else if entity = '&hellip;' then
          outStr := outStr + '…'
        else if entity = '&ndash;' then
          outStr := outStr + '–'
        else if entity = '&mdash;' then
          outStr := outStr + '—'
        else if entity = '&laquo;' then
          outStr := outStr + '«'
        else if entity = '&raquo;' then
          outStr := outStr + '»'
        else if entity = '&ldquo;' then
          outStr := outStr + '“'
        else if entity = '&rdquo;' then
          outStr := outStr + '”'
        else if entity = '&lsquo;' then
          outStr := outStr + '‘'
        else if entity = '&rsquo;' then
          outStr := outStr + '’'
        else if (Length(entity) > 3) and (entity[2] = '#') then
        begin
          numStr := Copy(entity, 3, Length(entity) - 3);
          if numStr <> '' then
          begin
            if numStr[1] = 'x' then
              codePoint := StrToIntDef('$' + Copy(numStr, 2, Length(numStr) - 1), 0)
            else
              codePoint := StrToIntDef(numStr, 0);
            if codePoint > 0 then
              outStr := outStr + UTF8Encode(widechar(codePoint));
          end;
        end
        else
        begin
          outStr := outStr + Copy(S, i, j - i + 1);
        end;
        i := j + 1;
      end
      else
      begin
        outStr := outStr + '&';
        Inc(i);
      end;
    end
    else
    begin
      outStr := outStr + S[i];
      Inc(i);
    end;
  end;
  Result := outStr;
end;

procedure THtmlParser.AddParIfNeeded;
begin
  if (FResult <> '') and (not FLastWasBlock) then
  begin
    FResult := FResult + '\par ';
  end;
  // Always mark as block after paragraph break or block start
  FLastWasBlock := True;
  FPendingSpace := False;
end;

function THtmlParser.ExtractAttribute(const Tag, Attr: string): string;
var
  lowerTag, lowerAttr: string;
  attrPos, eqPos, startPos, endPos: integer;
  quoteChar: char;
begin
  Result := '';
  lowerTag := LowerCase(Tag);
  lowerAttr := LowerCase(Attr) + '=';
  attrPos := Pos(lowerAttr, lowerTag);
  while attrPos > 0 do
  begin
    if (attrPos = 1) or (lowerTag[attrPos - 1] in [' ', #9, #10, #13]) then
      break;
    attrPos := PosEx(lowerAttr, lowerTag, attrPos + 1);
  end;
  if attrPos = 0 then Exit;
  eqPos := attrPos + Length(lowerAttr);
  while (eqPos <= Length(Tag)) and (Tag[eqPos] in [' ', #9, #10, #13]) do
    Inc(eqPos);
  if eqPos > Length(Tag) then Exit;
  quoteChar := Tag[eqPos];
  if quoteChar in ['''', '"'] then
  begin
    Inc(eqPos);
    startPos := eqPos;
    while (eqPos <= Length(Tag)) and (Tag[eqPos] <> quoteChar) do
      Inc(eqPos);
    endPos := eqPos - 1;
  end
  else
  begin
    startPos := eqPos;
    while (eqPos <= Length(Tag)) and not (Tag[eqPos] in [' ', #9, #10, #13, '>']) do
      Inc(eqPos);
    endPos := eqPos - 1;
  end;
  Result := Copy(Tag, startPos, endPos - startPos + 1);
end;

function THtmlParser.ExtractFontFamily(const Style: string): string;
var
  lower: string;
  pos1, pos2: integer;
begin
  Result := '';
  lower := LowerCase(Style);
  pos1 := Pos('font-family:', lower);
  if pos1 = 0 then Exit;
  pos1 := pos1 + Length('font-family:');
  // Skip spaces
  while (pos1 <= Length(Style)) and (Style[pos1] in [' ', #9]) do Inc(pos1);
  if pos1 > Length(Style) then Exit;
  // Find end of value (semicolon or end)
  pos2 := PosEx(';', Style, pos1);
  if pos2 = 0 then pos2 := Length(Style) + 1;
  Result := Copy(Style, pos1, pos2 - pos1);
  // Remove quotes
  Result := Trim(Result);
  if (Length(Result) >= 2) and (Result[1] in ['''', '"']) and (Result[Length(Result)] = Result[1]) then
    Result := Copy(Result, 2, Length(Result) - 2);
  // Take first family before comma
  pos1 := Pos(',', Result);
  if pos1 > 0 then
    Result := Trim(Copy(Result, 1, pos1 - 1));
end;

procedure THtmlParser.ProcessTag(const Tag: string);
var
  lowerTag, Name, attrStr: string;
  closeTag: boolean;
  i: integer;
begin
  lowerTag := Trim(Tag);
  if lowerTag = '' then Exit;
  if lowerTag[1] = '/' then
  begin
    closeTag := True;
    lowerTag := Copy(lowerTag, 2, Length(lowerTag) - 1);
  end
  else
    closeTag := False;

  if (Length(lowerTag) > 0) and (lowerTag[Length(lowerTag)] = '/') then
    lowerTag := Copy(lowerTag, 1, Length(lowerTag) - 1);

  i := 1;
  while (i <= Length(lowerTag)) and not (lowerTag[i] in [' ', #9, #10, #13]) do
    Inc(i);
  Name := LowerCase(Copy(lowerTag, 1, i - 1));
  attrStr := Trim(Copy(lowerTag, i, Length(lowerTag) - i + 1));

  if closeTag then
    ProcessClosingTag(Name)
  else
    ProcessOpeningTag(Name, attrStr);
end;

procedure THtmlParser.ProcessOpeningTag(const Name, AttrString: string);
var
  StartAttr: string;
  StyleStr: string;
  FontName: string;
  FontIdx: integer;
  SizeAttr: string;
  SizeVal: integer;
  SizeStr: string;
  FontSizeVal: integer;
begin
  if Name = 'b' then
  begin
    Inc(FFormat.Bold);
    if FUseInlineFormatting then FResult := FResult + '\b ';
  end
  else if Name = 'strong' then
  begin
    Inc(FFormat.Bold);
    if FUseInlineFormatting then FResult := FResult + '\b ';
  end
  else if Name = 'i' then
  begin
    Inc(FFormat.Italic);
    if FUseInlineFormatting then FResult := FResult + '\i ';
  end
  else if Name = 'em' then
  begin
    Inc(FFormat.Italic);
    if FUseInlineFormatting then FResult := FResult + '\i ';
  end
  else if Name = 'u' then
  begin
    Inc(FFormat.Underline);
    if FUseInlineFormatting then FResult := FResult + '\ul ';
  end
  else if Name = 'ins' then
  begin
    Inc(FFormat.Underline);
    if FUseInlineFormatting then FResult := FResult + '\ul ';
  end
  else if (Name = 'del') or (Name = 's') or (Name = 'strike') then
  begin
    Inc(FFormat.Strike);
    if FUseInlineFormatting then FResult := FResult + '\strike ';
  end
  else if Name = 'code' then Inc(FFormat.Code)
  else if Name = 'kbd' then Inc(FFormat.Code)
  else if Name = 'samp' then Inc(FFormat.Code)
  else if Name = 'var' then Inc(FFormat.Code)
  else if Name = 'pre' then Inc(FFormat.Pre)
  else if Name = 'a' then
  begin
    if FFormat.Link = 0 then
    begin
      FFormat.LinkUrl := ExtractAttribute(AttrString, 'href');
    end;
    Inc(FFormat.Link);
  end
  else if Name = 'span' then
  begin
    // Handle inline style with font-family
    StyleStr := ExtractAttribute(AttrString, 'style');
    if StyleStr <> '' then
    begin
      FontName := ExtractFontFamily(StyleStr);
      if FontName <> '' then
      begin
        FontIdx := FFontTable.IndexOf(FontName);
        if FontIdx < 0 then
        begin
          FFontTable.Add(FontName);
          FontIdx := FFontTable.Count - 1;
        end;
        FFormat.FontIndex := FontIdx;
      end;
    end;

    // Handle inline style with font-size
    SizeStr := ExtractAttribute(AttrString, 'style');
    if SizeStr <> '' then
    begin
      FontSizeVal := ExtractFontSize(SizeStr);
      if FontSizeVal > 0 then
        // Convert pt to half-points
        FFormat.FontSize := FontSizeVal * 2;
    end;
  end
  else if Name = 'font' then
  begin
    // Handle <font face="...">
    FontName := ExtractAttribute(AttrString, 'face');
    if FontName <> '' then
    begin
      FontIdx := FFontTable.IndexOf(FontName);
      if FontIdx < 0 then
      begin
        FFontTable.Add(FontName);
        FontIdx := FFontTable.Count - 1;
      end;
      FFormat.FontIndex := FontIdx;
    end;

    // Handle inline style with font-size
    SizeStr := ExtractAttribute(AttrString, 'style');
    if SizeStr <> '' then
    begin
      FontSizeVal := ExtractFontSize(SizeStr);
      if FontSizeVal > 0 then
        // Convert pt to half-points
        FFormat.FontSize := FontSizeVal * 2;
    end;

    // Handle <font size="...">
    // HTML size can be 1..7 or relative like +1, -1, but we accept only absolute numbers for simplicity
    // Convert HTML size (1..7) to half-points roughly: 8pt, 10pt, 12pt, 14pt, 18pt, 24pt, 36pt
    // 1 => 16, 2 => 20, 3 => 24, 4 => 28, 5 => 36, 6 => 48, 7 => 72
    SizeAttr := ExtractAttribute(AttrString, 'size');
    if SizeAttr <> '' then
    begin
      SizeVal := StrToIntDef(SizeAttr, 0);
      if SizeVal > 0 then
      begin
        case SizeVal of
          1: FFormat.FontSize := FDefaultFontSize - 8;   // base - 4pt
          2: FFormat.FontSize := FDefaultFontSize - 4;   // base - 2pt
          3: FFormat.FontSize := FDefaultFontSize;       // base
          4: FFormat.FontSize := FDefaultFontSize + 4;   // base + 2pt
          5: FFormat.FontSize := FDefaultFontSize + 8;   // base + 4pt
          6: FFormat.FontSize := FDefaultFontSize + 12;  // base + 6pt
          7: FFormat.FontSize := FDefaultFontSize + 16;  // base + 8pt
        end;
      end;
    end;
  end
  else if Name = 'p' then
  begin
    AddParIfNeeded;
  end
  else if Name = 'div' then
  begin
    AddParIfNeeded;
  end
  else if Name = 'br' then
  begin
    FResult := FResult + '\par ';
    FLastWasBlock := True;
    FPendingSpace := False;
  end
  else if Name = 'hr' then
  begin
    AddParIfNeeded;
    FResult := FResult + '\pard\brdrb\brdrs\brdrw10\brsp20 \par ';
    FLastWasBlock := True;
    FPendingSpace := False;
  end
  else if (Name = 'h1') or (Name = 'h2') or (Name = 'h3') or (Name = 'h4') or (Name = 'h5') or (Name = 'h6') then
  begin
    AddParIfNeeded;
    Inc(FFormat.Bold);
    if FUseInlineFormatting then FResult := FResult + '\b ';
    // Set heading sizes relative to default font size.
    // Additions are in half-points: 12pt -> 24, 8pt -> 16, 6pt -> 12, 4pt -> 8, 2pt -> 4, 1pt -> 2
    if Name = 'h1' then FFormat.FontSize := FDefaultFontSize + 24
    else if Name = 'h2' then FFormat.FontSize := FDefaultFontSize + 16
    else if Name = 'h3' then FFormat.FontSize := FDefaultFontSize + 12
    else if Name = 'h4' then FFormat.FontSize := FDefaultFontSize + 8
    else if Name = 'h5' then FFormat.FontSize := FDefaultFontSize + 4
    else if Name = 'h6' then FFormat.FontSize := FDefaultFontSize + 2;
  end
  else if Name = 'ul' then
    IncreaseListLevel('ul', 0)
  else if Name = 'ol' then
  begin
    StartAttr := ExtractAttribute(AttrString, 'start');
    if StartAttr <> '' then
      IncreaseListLevel('ol', StrToIntDef(StartAttr, 1))
    else
      IncreaseListLevel('ol', 1);
  end
  else if Name = 'li' then
  begin
    if FListLevel > 0 then
    begin
      if FResult <> '' then
        AddParIfNeeded;
      AddListItemMarker;
    end;
  end
  else if Name = 'table' then
  begin
    AddParIfNeeded;
  end
  else if Name = 'tr' then
  begin
    AddParIfNeeded;
  end
  else if Name = 'td' then
  begin
    FResult := FResult + '\tab ';
    FLastWasBlock := False;
  end
  else if Name = 'th' then
  begin
    FResult := FResult + '\tab ';
    FLastWasBlock := False;
  end
  else if Name = 'head' then
  begin
    FInSkipTag := '</head>';
    FSkipDepth := 1;
  end
  else if Name = 'script' then
  begin
    FInSkipTag := '</script>';
    FSkipDepth := 1;
  end
  else if Name = 'style' then
  begin
    FInSkipTag := '</style>';
    FSkipDepth := 1;
  end
  else if Name = 'svg' then
  begin
    FInSkipTag := '</svg>';
    FSkipDepth := 1;
  end
  else if Name = 'noscript' then
  begin
    FInSkipTag := '</noscript>';
    FSkipDepth := 1;
  end;
end;

procedure THtmlParser.ProcessClosingTag(const Name: string);
begin
  if Name = 'b' then
  begin
    if FFormat.Bold > 0 then
    begin
      Dec(FFormat.Bold);
      if FUseInlineFormatting then FResult := FResult + '\b0';
    end;
  end
  else if Name = 'strong' then
  begin
    if FFormat.Bold > 0 then
    begin
      Dec(FFormat.Bold);
      if FUseInlineFormatting then FResult := FResult + '\b0';
    end;
  end
  else if Name = 'i' then
  begin
    if FFormat.Italic > 0 then
    begin
      Dec(FFormat.Italic);
      if FUseInlineFormatting then FResult := FResult + '\i0';
    end;
  end
  else if Name = 'em' then
  begin
    if FFormat.Italic > 0 then
    begin
      Dec(FFormat.Italic);
      if FUseInlineFormatting then FResult := FResult + '\i0';
    end;
  end
  else if Name = 'u' then
  begin
    if FFormat.Underline > 0 then
    begin
      Dec(FFormat.Underline);
      if FUseInlineFormatting then FResult := FResult + '\ul0';
    end;
  end
  else if Name = 'ins' then
  begin
    if FFormat.Underline > 0 then
    begin
      Dec(FFormat.Underline);
      if FUseInlineFormatting then FResult := FResult + '\ul0';
    end;
  end
  else if (Name = 'del') or (Name = 's') or (Name = 'strike') then
  begin
    if FFormat.Strike > 0 then
    begin
      Dec(FFormat.Strike);
      if FUseInlineFormatting then FResult := FResult + '\strike0';
    end;
  end
  else if Name = 'code' then
  begin
    if FFormat.Code > 0 then Dec(FFormat.Code);
  end
  else if Name = 'kbd' then
  begin
    if FFormat.Code > 0 then Dec(FFormat.Code);
  end
  else if Name = 'samp' then
  begin
    if FFormat.Code > 0 then Dec(FFormat.Code);
  end
  else if Name = 'var' then
  begin
    if FFormat.Code > 0 then Dec(FFormat.Code);
  end
  else if Name = 'pre' then
  begin
    if FFormat.Pre > 0 then Dec(FFormat.Pre);
  end
  else if Name = 'a' then
  begin
    if FFormat.Link > 0 then
    begin
      Dec(FFormat.Link);
      if FFormat.Link = 0 then
        FFormat.LinkUrl := '';
    end;
  end
  else if Name = 'span' then
  begin
    // Reset font to default when closing span (simplistic approach)
    FFormat.FontIndex := 0;
    FFormat.FontSize := 0; // Reset to default
  end
  else if Name = 'font' then
  begin
    FFormat.FontIndex := 0;
    FFormat.FontSize := 0; // Reset to default
  end
  else if Name = 'p' then
  begin
    AddParIfNeeded;
    // Add an empty line after paragraph to match HTML vertical spacing
    FResult := FResult + '\par ';
    FLastWasBlock := True;
    FPendingSpace := False;
  end
  else if Name = 'div' then
  begin
    AddParIfNeeded;
    // Add an empty line after div block
    FResult := FResult + '\par ';
    FLastWasBlock := True;
    FPendingSpace := False;
  end
  else if (Name = 'h1') or (Name = 'h2') or (Name = 'h3') or (Name = 'h4') or (Name = 'h5') or (Name = 'h6') then
  begin
    if FFormat.Bold > 0 then
    begin
      Dec(FFormat.Bold);
      if FUseInlineFormatting then FResult := FResult + '\b0';
    end;
    FFormat.FontSize := 0; // Reset to default size
    AddParIfNeeded;
    // Add an empty line after h block
    FResult := FResult + '\par ';
    FLastWasBlock := True;
    FPendingSpace := False;
  end
  else if Name = 'ul' then
    DecreaseListLevel
  else if Name = 'ol' then
    DecreaseListLevel
  else if Name = 'li' then
  begin
    AddParIfNeeded;
  end
  else if Name = 'table' then
  begin
    AddParIfNeeded;
  end
  else if Name = 'tr' then
  begin
    AddParIfNeeded;
  end
  else if Name = 'td' then
  begin
    // end cell, no extra action
  end
  else if Name = 'th' then
  begin
  end;
end;

procedure THtmlParser.IncreaseListLevel(const ListType: string; StartValue: integer);
begin
  if FListLevel < MaxListLevel then
  begin
    Inc(FListLevel);
    FListStack[FListLevel].ListType := ListType;
    if ListType = 'ol' then
      FListStack[FListLevel].Counter := StartValue - 1
    else
      FListStack[FListLevel].Counter := 0;
  end;
end;

procedure THtmlParser.DecreaseListLevel;
begin
  if FListLevel > 0 then
    Dec(FListLevel);
end;

procedure THtmlParser.AddListItemMarker;
var
  Indent: integer;
begin
  if FListLevel = 0 then Exit;
  // Set left indent depending on list depth.
  // 720 twips = 0.5 inch per level.
  Indent := FListLevel * 200;
  FResult := FResult + '\pard\li' + IntToStr(Indent) + ' ';
  if FListStack[FListLevel].ListType = 'ul' then
    FResult := FResult + '{\pntext\f1\bullet} '
  else
  begin
    Inc(FListStack[FListLevel].Counter);
    FResult := FResult + '{\pntext\f0 ' + IntToStr(FListStack[FListLevel].Counter) + '.} ';
  end;
  FLastWasBlock := True;
  FPendingSpace := False;
end;

function THtmlParser.ExtractFontSize(const Style: string): integer;
var
  lower: string;
  pos1, pos2: integer;
  numStr: string;
begin
  Result := 0;
  lower := LowerCase(Style);
  pos1 := Pos('font-size:', lower);
  if pos1 = 0 then Exit;
  pos1 := pos1 + Length('font-size:');
  while (pos1 <= Length(Style)) and (Style[pos1] in [' ', #9]) do Inc(pos1);
  if pos1 > Length(Style) then Exit;
  pos2 := PosEx(';', Style, pos1);
  if pos2 = 0 then pos2 := Length(Style) + 1;
  numStr := Trim(Copy(Style, pos1, pos2 - pos1));
  // Accept formats like "12pt", "12 pt", "12px" (ignoring units)
  pos2 := 1;
  while (pos2 <= Length(numStr)) and (numStr[pos2] in ['0'..'9', '-']) do Inc(pos2);
  numStr := Copy(numStr, 1, pos2 - 1);
  Result := StrToIntDef(numStr, 0);
end;

function ConvertHtmlToRtf(const Html: string; DefaultFontSizePt: integer; AsFragment: boolean = False;
  UseInlineFormatting: boolean = False): string;
var
  Parser: THtmlParser;
begin
  Parser := THtmlParser.Create(Html, DefaultFontSizePt, AsFragment, UseInlineFormatting);
  try
    Result := Parser.Convert;
  finally
    Parser.Free;
  end;
end;

end.
