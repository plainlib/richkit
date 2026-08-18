unit RtfToHtml;

{$mode objfpc}{$H+}

interface

// Convert RTF string to HTML
function ConvertRtfToHtml(const Rtf: string): string;

implementation

uses
  SysUtils, Classes, StrUtils, LConvEncoding, LazUTF8;

const
  MaxListLevel = 9; // Maximum nesting level for lists

type
  TRtfState = record
    Bold: boolean;
    Italic: boolean;
    Underline: boolean;
    FontName: string; // Font family name for current run
    FontSize: integer; // Font size in half-points, 0 means default
  end;

  TListInfo = record
    ListType: string; // 'ul' or 'ol'
    Indent: integer;   // List indent in twips
  end;

function EscapeHtml(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&#39;', [rfReplaceAll]);
end;

function FormatText(const S: string; State: TRtfState): string;
var
  Escaped, StyleStr: string;
begin
  Escaped := EscapeHtml(S);
  if State.Bold then
    Escaped := '<strong>' + Escaped + '</strong>';
  if State.Italic then
    Escaped := '<em>' + Escaped + '</em>';
  if State.Underline then
    Escaped := '<u>' + Escaped + '</u>';
  StyleStr := '';
  if State.FontName <> '' then
    StyleStr := StyleStr + 'font-family: ' + State.FontName;
  if State.FontSize > 0 then
  begin
    if StyleStr <> '' then StyleStr := StyleStr + '; ';
    StyleStr := StyleStr + 'font-size: ' + IntToStr(State.FontSize div 2) + 'pt';
  end;
  if StyleStr <> '' then
    Escaped := '<span style="' + StyleStr + ';">' + Escaped + '</span>';
  Result := Escaped;
end;

function ConvertRtfToHtml(const Rtf: string): string;
var
  i: integer;
  ch: char;
  state: TRtfState;
  rawBytes: ansistring;
  html: string;
  groupStates: array of TRtfState = nil;
  groupDepth: integer;
  skipGroupDepth: integer;
  inSkipGroup: boolean;
  controlWord: string;
  param: integer;
  hasParam: boolean;
  startPos: integer;
  hexStr: string;
  codepage: string;
  unicodeSkip: integer;
  currentRunText: string;
  currentRunFormat: TRtfState;
  paragraphText: string;
  // List handling
  listLevel: integer;
  listStack: array[0..MaxListLevel] of TListInfo;
  // Current list item state
  inListItem: boolean;
  currentListItemContent: string;
  // Current paragraph indent in twips
  currentIndent: integer;
  // Marker group handling
  inListItemMarker: boolean;
  markerText: string;
  // Font table
  FontTable: array of string;
  IsFontTable: boolean;
  FontTableDepth: integer;
  FontTableText: string;

  function IsOnlyWhitespaceHtml(const S: string): boolean;
  var
    i: integer;
    inTag: boolean;
  begin
    Result := True;
    inTag := False;
    for i := 1 to Length(S) do
    begin
      if S[i] = '<' then inTag := True
      else if S[i] = '>' then inTag := False
      else if not inTag then
        if not (S[i] in [' ', #9, #10, #13]) then
        begin
          Result := False;
          Exit;
        end;
    end;
  end;

  function IsIgnorableGroupStart(const RtfStr: string; pos: integer): boolean;
  var
    p: integer;
    wordStart: integer;
    word: string;
  begin
    Result := False;
    if pos > Length(RtfStr) then Exit;
    p := pos;
    while (p <= Length(RtfStr)) and (RtfStr[p] in [#9, #10, #13, ' ']) do Inc(p);
    if p > Length(RtfStr) then Exit;
    if RtfStr[p] = '\' then
    begin
      Inc(p);
      if p <= Length(RtfStr) then
      begin
        if RtfStr[p] = '*' then
        begin
          Result := True;
          Exit;
        end;
        if RtfStr[p] in ['a'..'z', 'A'..'Z'] then
        begin
          wordStart := p;
          while (p <= Length(RtfStr)) and (RtfStr[p] in ['a'..'z', 'A'..'Z']) do Inc(p);
          word := LowerCase(Copy(RtfStr, wordStart, p - wordStart));
          if (word = 'colortbl') or (word = 'stylesheet') or (word = 'info') or (word = 'generator') or
            (word = 'mmathpr') or (word = 'viewkind') or (word = 'nouicompat') or (word = 'mwrapindent') or
            (word = 'mmathfont') then
            Result := True;
        end;
      end;
    end;
  end;

  procedure FlushRawBytes;
  var
    converted: string;
  begin
    if rawBytes <> '' then
    begin
      converted := LConvEncoding.ConvertEncoding(rawBytes, codepage, 'utf8');
      currentRunText := currentRunText + converted;
      rawBytes := '';
    end;
  end;

  procedure FlushRun;
  begin
    FlushRawBytes;
    if currentRunText <> '' then
    begin
      paragraphText := paragraphText + FormatText(currentRunText, currentRunFormat);
      currentRunText := '';
    end;
  end;

  procedure CloseCurrentListItem;
  begin
    if inListItem then
    begin
      html := html + '<li>' + currentListItemContent + '</li>' + LineEnding;
      inListItem := False;
      currentListItemContent := '';
    end;
  end;

  procedure CloseListLevelsAbove(NewLevel: integer);
  begin
    while listLevel > NewLevel do
    begin
      CloseCurrentListItem;
      html := html + '</' + listStack[listLevel].ListType + '>' + LineEnding;
      Dec(listLevel);
    end;
  end;

  procedure UpdateListLevel(Indent: integer; ListType: string);
  begin
    // Close levels with deeper indent
    while (listLevel > 0) and (listStack[listLevel].Indent > Indent) do
    begin
      CloseCurrentListItem;
      html := html + '</' + listStack[listLevel].ListType + '>' + LineEnding;
      Dec(listLevel);
    end;

    if listLevel = 0 then
    begin
      // Start a new list at level 1
      Inc(listLevel);
      listStack[listLevel].ListType := ListType;
      listStack[listLevel].Indent := Indent;
      html := html + '<' + ListType + '>' + LineEnding;
    end
    else if listStack[listLevel].Indent = Indent then
    begin
      // Same indent level, check list type
      if listStack[listLevel].ListType <> ListType then
      begin
        // Close current list and start a new one of different type
        CloseCurrentListItem;
        html := html + '</' + listStack[listLevel].ListType + '>' + LineEnding;
        listStack[listLevel].ListType := ListType;
        html := html + '<' + ListType + '>' + LineEnding;
      end;
    end
    else if listStack[listLevel].Indent < Indent then
    begin
      // Deeper level
      if listLevel < MaxListLevel then
      begin
        Inc(listLevel);
        listStack[listLevel].ListType := ListType;
        listStack[listLevel].Indent := Indent;
        html := html + '<' + ListType + '>' + LineEnding;
      end;
    end;
  end;

  procedure EndParagraph;
  var
    trimmed: string;
  begin
    FlushRun;
    trimmed := Trim(paragraphText);
    paragraphText := '';
    if trimmed = '' then Exit;
    if IsOnlyWhitespaceHtml(trimmed) then Exit;

    if inListItem then
    begin
      // Continuation of current list item
      currentListItemContent := currentListItemContent + '<br>' + trimmed;
    end
    else
    begin
      // Regular paragraph outside list
      CloseCurrentListItem;
      CloseListLevelsAbove(0);
      html := html + '<p>' + trimmed + '</p>' + LineEnding;
    end;
  end;

  procedure ProcessMarkerGroup;
  var
    marker, listType: string;
  begin
    marker := Trim(markerText);
    if marker = '' then Exit;
    if (marker = '\bullet') or (marker = '•') or (marker = '·') or (marker = '◦') then
      listType := 'ul'
    else if (Length(marker) > 1) and (marker[1] in ['0'..'9']) and (marker[Length(marker)] in ['.', ')', ':']) then
      listType := 'ol'
    else
      Exit;

    // Close previous list item if any
    CloseCurrentListItem;
    // Update list level based on currentIndent
    UpdateListLevel(currentIndent, listType);
    // Start accumulating new list item
    currentListItemContent := '';
    inListItem := True;
  end;

  procedure ParseFontTable(const S: string);
  var
    i, j, p, nameStart: integer;
    num: integer;
    Name: string;
  begin
    SetLength(FontTable, 0);
    i := 1;
    while i <= Length(S) do
    begin
      if (i + 1 <= Length(S)) and (S[i] = '\') and (S[i + 1] = 'f') then
      begin
        j := i + 2;
        while (j <= Length(S)) and (S[j] in ['0'..'9']) do Inc(j);
        if j > i + 2 then
        begin
          num := StrToIntDef(Copy(S, i + 2, j - (i + 2)), -1);
          if num >= 0 then
          begin
            p := j;
            while p <= Length(S) do
            begin
              if S[p] = '\' then
              begin
                Inc(p);
                if (p <= Length(S)) and (S[p] in ['a'..'z', 'A'..'Z']) then
                begin
                  while (p <= Length(S)) and (S[p] in ['a'..'z', 'A'..'Z']) do Inc(p);
                  while (p <= Length(S)) and (S[p] in ['0'..'9']) do Inc(p);
                  if (p <= Length(S)) and (S[p] = ' ') then Inc(p);
                end
                else
                begin
                  Inc(p, 2);
                end;
              end
              else if (S[p] = ';') or (S[p] = '}') then
              begin
                break;
              end
              else if S[p] = '{' then
              begin
                Inc(p);
                while (p <= Length(S)) and (S[p] <> '}') do Inc(p);
                if p <= Length(S) then Inc(p);
              end
              else
              begin
                nameStart := p;
                while (p <= Length(S)) and (S[p] <> ';') and (S[p] <> '}') do Inc(p);
                Name := Trim(Copy(S, nameStart, p - nameStart));
                if num >= Length(FontTable) then
                  SetLength(FontTable, num + 1);
                FontTable[num] := Name;
                i := p;
                break;
              end;
            end;
          end;
        end;
        if i < j then i := j;
      end
      else
        Inc(i);
    end;
  end;

begin
  // Initialize variables
  state.Bold := False;
  state.Italic := False;
  state.Underline := False;
  state.FontName := '';
  state.FontSize := 0;
  rawBytes := '';
  html := '';
  groupDepth := 0;
  skipGroupDepth := 0;
  inSkipGroup := False;
  codepage := 'cp1252';
  unicodeSkip := 1;
  currentRunText := '';
  currentRunFormat := state;
  paragraphText := '';
  listLevel := 0;
  for i := 0 to MaxListLevel do
  begin
    listStack[i].ListType := '';
    listStack[i].Indent := 0;
  end;
  inListItem := False;
  currentListItemContent := '';
  currentIndent := 0;
  inListItemMarker := False;
  markerText := '';
  SetLength(groupStates, 1);
  groupStates[0] := state;
  SetLength(FontTable, 0);
  IsFontTable := False;
  FontTableDepth := 0;
  FontTableText := '';

  i := 1;
  while i <= Length(Rtf) do
  begin
    ch := Rtf[i];

    if inSkipGroup then
    begin
      if ch = '{' then
        Inc(skipGroupDepth)
      else if ch = '}' then
      begin
        Dec(skipGroupDepth);
        if skipGroupDepth = 0 then
          inSkipGroup := False;
      end;
      Inc(i);
      continue;
    end;

    if IsFontTable then
    begin
      if ch = '{' then
        Inc(FontTableDepth)
      else if ch = '}' then
      begin
        Dec(FontTableDepth);
        if FontTableDepth = 0 then
        begin
          ParseFontTable(FontTableText);
          IsFontTable := False;
          Inc(i);
          continue;
        end;
      end
      else
        FontTableText := FontTableText + ch;
      Inc(i);
      continue;
    end;

    if ch = '{' then
    begin
      if (i + 8 <= Length(Rtf)) and (LowerCase(Copy(Rtf, i + 1, 8)) = '\fonttbl') then
      begin
        FlushRun;
        IsFontTable := True;
        FontTableDepth := 1;
        FontTableText := '';
        Inc(i);
        continue;
      end;

      // Detect list marker group \pntext or \listtext
      if (i + 8 <= Length(Rtf)) and (LowerCase(Copy(Rtf, i + 1, 7)) = '\pntext') then
      begin
        FlushRun;
        inListItemMarker := True;
        markerText := '';
        Inc(i);
        continue;
      end
      else if (i + 9 <= Length(Rtf)) and (LowerCase(Copy(Rtf, i + 1, 8)) = '\listtext') then
      begin
        FlushRun;
        inListItemMarker := True;
        markerText := '';
        Inc(i);
        continue;
      end;

      if IsIgnorableGroupStart(Rtf, i + 1) then
      begin
        inSkipGroup := True;
        skipGroupDepth := 1;
        Inc(i);
        continue;
      end;

      FlushRun;
      Inc(groupDepth);
      SetLength(groupStates, groupDepth + 1);
      groupStates[groupDepth] := state;
      Inc(i);
      continue;
    end
    else if ch = '}' then
    begin
      FlushRun;
      if inListItemMarker then
      begin
        inListItemMarker := False;
        ProcessMarkerGroup;
      end
      else if groupDepth > 0 then
      begin
        state := groupStates[groupDepth];
        Dec(groupDepth);
        SetLength(groupStates, groupDepth + 1);
        currentRunFormat := state;
      end;
      Inc(i);
      continue;
    end
    else if ch = '\' then
    begin
      if i < Length(Rtf) then
      begin
        if Rtf[i + 1] = '{' then
        begin
          rawBytes := rawBytes + ansichar('{');
          Inc(i, 2);
          continue;
        end
        else if Rtf[i + 1] = '}' then
        begin
          rawBytes := rawBytes + ansichar('}');
          Inc(i, 2);
          continue;
        end
        else if Rtf[i + 1] = '\' then
        begin
          rawBytes := rawBytes + ansichar('\');
          Inc(i, 2);
          continue;
        end
        else if Rtf[i + 1] in ['a'..'z', 'A'..'Z'] then
        begin
          Inc(i);
          startPos := i;
          while (i <= Length(Rtf)) and (Rtf[i] in ['a'..'z', 'A'..'Z']) do
            Inc(i);
          controlWord := LowerCase(Copy(Rtf, startPos, i - startPos));
          param := 0;
          hasParam := False;
          if (i <= Length(Rtf)) and (Rtf[i] = '-') then
          begin
            Inc(i);
            while (i <= Length(Rtf)) and (Rtf[i] in ['0'..'9']) do Inc(i);
            hasParam := True;
          end
          else if (i <= Length(Rtf)) and (Rtf[i] in ['0'..'9']) then
          begin
            startPos := i;
            while (i <= Length(Rtf)) and (Rtf[i] in ['0'..'9']) do Inc(i);
            param := StrToIntDef(Copy(Rtf, startPos, i - startPos), 0);
            hasParam := True;
          end;
          // Skip only one delimiter space if present
          if (i <= Length(Rtf)) and (Rtf[i] = ' ') then
            Inc(i);

          if controlWord = 'b' then
          begin
            FlushRun;
            state.Bold := (not hasParam) or (param <> 0);
            currentRunFormat := state;
          end
          else if controlWord = 'i' then
          begin
            FlushRun;
            state.Italic := (not hasParam) or (param <> 0);
            currentRunFormat := state;
          end
          else if controlWord = 'ul' then
          begin
            FlushRun;
            state.Underline := (not hasParam) or (param <> 0);
            currentRunFormat := state;
          end
          else if controlWord = 'fs' then
          begin
            FlushRun;
            state.FontSize := param;
            currentRunFormat := state;
          end
          else if controlWord = 'pard' then
          begin
            currentIndent := 0;
          end
          else if controlWord = 'li' then
          begin
            if hasParam then
              currentIndent := param
            else
              currentIndent := 0;
          end
          else if controlWord = 'par' then
          begin
            EndParagraph;
          end
          else if controlWord = 'line' then
          begin
            FlushRun;
            paragraphText := paragraphText + '<br>';
          end
          else if controlWord = 'tab' then
          begin
            FlushRawBytes;
            currentRunText := currentRunText + '    ';
          end
          else if controlWord = 'bullet' then
          begin
            FlushRawBytes;
            if inListItemMarker then
              markerText := markerText + '\bullet'
            else
              currentRunText := currentRunText + '•';
          end
          else if controlWord = 'endash' then
          begin
            FlushRawBytes;
            currentRunText := currentRunText + '–';
          end
          else if controlWord = 'emdash' then
          begin
            FlushRawBytes;
            currentRunText := currentRunText + '—';
          end
          else if controlWord = 'lquote' then
          begin
            FlushRawBytes;
            currentRunText := currentRunText + '‘';
          end
          else if controlWord = 'rquote' then
          begin
            FlushRawBytes;
            currentRunText := currentRunText + '’';
          end
          else if controlWord = 'ldblquote' then
          begin
            FlushRawBytes;
            currentRunText := currentRunText + '“';
          end
          else if controlWord = 'rdblquote' then
          begin
            FlushRawBytes;
            currentRunText := currentRunText + '”';
          end
          else if controlWord = 'ansicpg' then
          begin
            if hasParam then
            begin
              case param of
                1251: codepage := 'cp1251';
                1252: codepage := 'cp1252';
                65001: codepage := 'utf8';
                else
                  codepage := 'cp1252';
              end;
            end;
          end
          else if controlWord = 'uc' then
          begin
            if hasParam then
              unicodeSkip := param;
          end
          else if controlWord = 'u' then
          begin
            FlushRawBytes;
            if hasParam then
              currentRunText := currentRunText + UTF8Encode(widechar(param));
            for startPos := 1 to unicodeSkip do
            begin
              if (i <= Length(Rtf)) and (Rtf[i] <> ' ') then
                Inc(i);
            end;
          end
          else if controlWord = 'f' then
          begin
            FlushRun;
            if hasParam and (param >= 0) and (param < Length(FontTable)) then
              state.FontName := FontTable[param]
            else
              state.FontName := '';
            currentRunFormat := state;
          end
          else if controlWord = 'lang' then
          begin
            FlushRun;
            currentRunFormat := state;
          end;
          continue;
        end
        else
        begin
          case Rtf[i + 1] of
            #39:
            begin
              if i + 2 <= Length(Rtf) then
              begin
                hexStr := Copy(Rtf, i + 2, 2);
                try
                  rawBytes := rawBytes + ansichar(StrToInt('$' + hexStr));
                except
                end;
                Inc(i, 4);
              end;
            end;
            '~':
            begin
              rawBytes := rawBytes + ansichar(' ');
              Inc(i, 2);
            end;
            '-':
            begin
              rawBytes := rawBytes + ansichar('-');
              Inc(i, 2);
            end;
            else
              Inc(i, 2);
          end;
          continue;
        end;
      end
      else
      begin
        rawBytes := rawBytes + ansichar('\');
        Inc(i);
        continue;
      end;
    end
    else
    begin
      rawBytes := rawBytes + ansichar(ch);
      Inc(i);
    end;
  end;

  // Finalize any remaining paragraph
  EndParagraph;
  // Close any open list item
  CloseCurrentListItem;
  // Close all open lists
  CloseListLevelsAbove(0);

  Result := html;
end;

end.
