//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit SpellUtils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Graphics,
  RichMemo,
  {$IFDEF WINDOWS}
  WinSpellChecker,
  {$ENDIF}
  RichSpellChecker;

type
  TSpell = class
  public
    // Checks the text of a RichMemo for spelling and/or grammar errors and applies wavy underlines
    class function WinCheck(ARichMemo: TRichMemo; ASpellChecker: TRichSpellChecker; const ALanguage: string;
      AOptions: TSpellCheckOptions = [scoSpelling]; AAddEmptySuggestions: boolean = True): boolean; static;

    // Returns a list of all available spell checker language tags in BCP-47 format
    class function WinSupportedLanguages: TStrings; static;

    // Checks plain text and returns an array of spell error items without touching GUI
    class function CheckText(const AText: string; const ALanguage: string; AOptions: TSpellCheckOptions = [scoSpelling];
      AAddEmptySuggestions: boolean = True): RichSpellChecker.TSpellErrorArray; static;

    // Applies a list of spell errors to the spell checker, replacing all existing underlines
    class procedure ApplyErrors(ASpellChecker: TRichSpellChecker; const AErrors: RichSpellChecker.TSpellErrorArray); static;
  end;

implementation

class function TSpell.WinCheck(ARichMemo: TRichMemo; ASpellChecker: TRichSpellChecker; const ALanguage: string;
  AOptions: TSpellCheckOptions = [scoSpelling]; AAddEmptySuggestions: boolean = True): boolean;
  {$IFDEF WINDOWS}
var
  WideText: widestring;
  Utf8Text: string;
  WinErrors: WinSpellChecker.TSpellErrorArray = nil;
  SuggestionList: array of string = nil;
  i, j: integer;
  StartPos, EndPos, ErrorLength: integer;
  {$ENDIF}
begin
  Result := False;
  {$IFDEF WINDOWS}
  if not Assigned(ARichMemo) or not Assigned(ASpellChecker) then
    Exit;

  // If no options selected, clear previous underlines and exit
  if AOptions = [] then
  begin
    ASpellChecker.BeginUpdate;
    try
      ASpellChecker.Clear;
    finally
      ASpellChecker.EndUpdate;
    end;
    Exit;
  end;

  // Get the text and convert it to WideString for the spell checker
  Utf8Text := ARichMemo.Text;
  WideText := UTF8Decode(Utf8Text);

  // Run the spell check with the specified options
  if not CheckSpelling(WideText, ALanguage, WinErrors, AOptions) then
    Exit;

  // Clear previous underlines
  ASpellChecker.BeginUpdate;
  try
    ASpellChecker.Clear;

    // Add errors using UTF-8 character positions
    for i := 0 to High(WinErrors) do
    begin
      StartPos := Utf16ToUtf8CharIndex(Utf8Text, WinErrors[i].Start);
      EndPos := Utf16ToUtf8CharIndex(Utf8Text, WinErrors[i].Start + WinErrors[i].Length);

      if (StartPos < 0) or (EndPos < StartPos) then
        Continue;

      ErrorLength := EndPos - StartPos;

      // Convert suggestions from WideString to UTF-8 String
      SetLength(SuggestionList, Length(WinErrors[i].Suggestions));
      for j := 0 to High(WinErrors[i].Suggestions) do
        SuggestionList[j] := UTF8Encode(WinErrors[i].Suggestions[j]);

      // Add the error using UTF-8 character positions
      if AAddEmptySuggestions or (Length(SuggestionList) > 0) then
      begin
        if WinErrors[i].ErrorType = setComprehensiveSpelling then
          ASpellChecker.AddError(StartPos, ErrorLength, 'Comprehensive Spelling error', SuggestionList, clFuchsia)
        else
          ASpellChecker.AddError(StartPos, ErrorLength, 'Spelling error', SuggestionList, clRed);
      end;
    end;
    Result := True;
  finally
    ASpellChecker.EndUpdate;
  end;
  {$ENDIF}
end;

class function TSpell.WinSupportedLanguages: TStrings;
  {$IFDEF WINDOWS}
var
  Langs: TSupportedLanguages;
  i: integer;
  LangList: TStringList = nil;
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  LangList := TStringList.Create;
  Langs := GetSupportedSpellCheckerLanguages;
  for i := 0 to High(Langs) do
    LangList.Add(UTF8Encode(Langs[i]));
  Result := LangList;
  {$ELSE}
  Result := TStringList.Create; // Empty list on non-Windows platforms
  {$ENDIF}
end;

class function TSpell.CheckText(const AText: string; const ALanguage: string; AOptions: TSpellCheckOptions = [scoSpelling];
  AAddEmptySuggestions: boolean = True): RichSpellChecker.TSpellErrorArray;
  {$IFDEF WINDOWS}
var
  WideText: widestring;
  WinErrors: WinSpellChecker.TSpellErrorArray = nil;
  i, j: integer;
  ResultIndex: integer;
  StartPos, EndPos, ErrorLength: integer;
  {$ENDIF}
begin
  Result := nil; // Explicit initialization to suppress warning
  {$IFDEF WINDOWS}
  if AOptions = [] then
    Exit;

  WideText := UTF8Decode(AText);

  if not CheckSpelling(WideText, ALanguage, WinErrors, AOptions) then
    Exit;

  SetLength(Result, 0); // Start with empty array
  ResultIndex := 0;

  for i := 0 to High(WinErrors) do
  begin
    StartPos := Utf16ToUtf8CharIndex(AText, WinErrors[i].Start);
    EndPos := Utf16ToUtf8CharIndex(AText, WinErrors[i].Start + WinErrors[i].Length);

    if (StartPos < 0) or (EndPos < StartPos) then
      Continue;

    ErrorLength := EndPos - StartPos;

    // If empty suggestions are not allowed and the list is empty, skip this error
    if not AAddEmptySuggestions and (Length(WinErrors[i].Suggestions) = 0) then
      Continue;

    // Increase result array size and fill the new item
    Inc(ResultIndex);
    SetLength(Result, ResultIndex);
    Result[ResultIndex - 1].Offset := StartPos;
    Result[ResultIndex - 1].Length := ErrorLength;

    if WinErrors[i].ErrorType = setComprehensiveSpelling then
    begin
      Result[ResultIndex - 1].Message := 'Comprehensive Spelling error';
      Result[ResultIndex - 1].Color := clFuchsia;
    end
    else
    begin
      Result[ResultIndex - 1].Message := 'Spelling error';
      Result[ResultIndex - 1].Color := clRed;
    end;

    // Copy suggestions from WideString to UTF-8 String
    SetLength(Result[ResultIndex - 1].Replacements, Length(WinErrors[i].Suggestions));
    for j := 0 to High(WinErrors[i].Suggestions) do
      Result[ResultIndex - 1].Replacements[j] := UTF8Encode(WinErrors[i].Suggestions[j]);
  end;
  {$ENDIF}
end;

class procedure TSpell.ApplyErrors(ASpellChecker: TRichSpellChecker; const AErrors: RichSpellChecker.TSpellErrorArray);
var
  i: integer;
begin
  if not Assigned(ASpellChecker) then
    Exit;

  ASpellChecker.BeginUpdate;
  try
    ASpellChecker.Clear;
    for i := 0 to High(AErrors) do
      ASpellChecker.AddError(
        AErrors[i].Offset,
        AErrors[i].Length,
        AErrors[i].Message,
        AErrors[i].Replacements,
        AErrors[i].Color);
  finally
    ASpellChecker.EndUpdate;
  end;
end;

end.
