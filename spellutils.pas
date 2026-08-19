//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit SpellUtils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, RichMemo, RichSpellChecker, WinSpellChecker;

type
  TSpell = class
  public
    // Checks the text of a RichMemo for spelling errors and applies wavy underlines
    class procedure CheckWinApi(ARichMemo: TRichMemo; ASpellChecker: TRichSpellChecker; const ALanguage: string); static;

  end;

implementation

class procedure TSpell.CheckWinApi(ARichMemo: TRichMemo; ASpellChecker: TRichSpellChecker; const ALanguage: string);
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
  {$IFDEF WINDOWS}
  if not Assigned(ARichMemo) or not Assigned(ASpellChecker) then
    Exit;

  // Get the text and convert it to WideString for the spell checker
  Utf8Text := ARichMemo.Text;
  WideText := UTF8Decode(Utf8Text);

  // Run the spell check
  if not CheckSpelling(WideText, ALanguage, Errors) then
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
      ASpellChecker.AddError(
        StartPos,
        ErrorLength,
        'Spelling error',
        SuggestionList
        );
    end;
  finally
    ASpellChecker.EndUpdate;
  end;
  {$ENDIF}
end;

end.
