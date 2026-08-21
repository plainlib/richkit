//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit SpellUtils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Graphics, RichMemo, RichSpellChecker, WinSpellChecker;

type
  TSpell = class
  public
    // Checks the text of a RichMemo for spelling and/or grammar errors and applies wavy underlines
    class function WinCheck(ARichMemo: TRichMemo; ASpellChecker: TRichSpellChecker; const ALanguage: string;
      AOptions: TSpellCheckOptions = [scoSpelling]; AAddEmptySuggestions: boolean = False): boolean; static;

    // Returns a list of all available spell checker language tags in BCP-47 format
    class function WinSupportedLanguages: TStrings; static;
  end;

implementation

class function TSpell.WinCheck(ARichMemo: TRichMemo; ASpellChecker: TRichSpellChecker; const ALanguage: string;
  AOptions: TSpellCheckOptions = [scoSpelling]; AAddEmptySuggestions: boolean = False): boolean;
  {$IFDEF WINDOWS}
var
  WideText: widestring;
  Utf8Text: string;
  Errors: TSpellErrorArray;
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
  if not CheckSpelling(WideText, ALanguage, Errors, AOptions) then
    Exit;

  // Clear previous underlines
  ASpellChecker.BeginUpdate;
  try
    ASpellChecker.Clear;

    // Add errors using UTF-8 character positions
    for i := 0 to High(Errors) do
    begin
      StartPos := Utf16ToUtf8CharIndex(Utf8Text, Errors[i].Start);
      EndPos := Utf16ToUtf8CharIndex(Utf8Text, Errors[i].Start + Errors[i].Length);

      if (StartPos < 0) or (EndPos < StartPos) then
        Continue;

      ErrorLength := EndPos - StartPos;

      // Convert suggestions from WideString to UTF-8 String
      SetLength(SuggestionList, Length(Errors[i].Suggestions));

      for j := 0 to High(Errors[i].Suggestions) do
        SuggestionList[j] := UTF8Encode(Errors[i].Suggestions[j]);

      // Add the error using UTF-8 character positions
      if AAddEmptySuggestions or (Length(SuggestionList)>0) then
      begin
        if Errors[i].ErrorType = setComprehensiveSpelling then
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
  LangList: TStringList;
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

end.
