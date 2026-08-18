unit WinSpellChecker;

{$mode objfpc}{$H+}
{$INTERFACES COM}

interface

{$IFDEF WINDOWS}

uses
  Classes, SysUtils, ActiveX, ComObj, LazUTF8;

type
  TSpellError = record
    Start: integer;
    Length: integer;
    Suggestions: array of widestring;
  end;

  TSpellErrorArray = array of TSpellError;

  IEnumString = interface(IUnknown)
    ['{00000101-0000-0000-C000-000000000046}']
    function Next(celt: longword; out rgelt: pwidechar; out pceltFetched: longword): HRESULT; stdcall;
    function Skip(celt: longword): HRESULT; stdcall;
    function Reset: HRESULT; stdcall;
    function Clone(out ppenum: IEnumString): HRESULT; stdcall;
  end;

  ISpellingError = interface(IUnknown)
    ['{B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3}']
    function GetStartIndex(out Value: longword): HRESULT; stdcall;
    function GetLength(out Value: longword): HRESULT; stdcall;
    function GetCorrectiveAction(out Value: longword): HRESULT; stdcall;
    function GetReplacement(out Value: pwidechar): HRESULT; stdcall;
  end;

  IEnumSpellingError = interface(IUnknown)
    ['{803E3BD4-2828-4410-8290-418D1D73C762}']
    function Next(out Value: ISpellingError): HRESULT; stdcall;
  end;

  ISpellChecker = interface(IUnknown)
    ['{B6FD0B71-E2BC-4653-8D05-F197E412770B}']
    function GetLanguageTag(out Value: pwidechar): HRESULT; stdcall;
    function Check(const Text: pwidechar; out Value: IEnumSpellingError): HRESULT; stdcall;
    function Suggest(const word: pwidechar; out Value: IEnumString): HRESULT; stdcall;
    function Add(const word: pwidechar): HRESULT; stdcall;
    function Ignore(const word: pwidechar): HRESULT; stdcall;
    function AutoCorrect(const from, to_: pwidechar): HRESULT; stdcall;
    function GetOptionValue(const optionId: pwidechar; out Value: byte): HRESULT; stdcall;
    function GetOptionIds(out Value: IEnumString): HRESULT; stdcall;
    function GetId(out Value: pwidechar): HRESULT; stdcall;
    function GetLocalizedName(out Value: pwidechar): HRESULT; stdcall;
    function AddSpellCheckerChanged(handler: IUnknown; out eventCookie: longword): HRESULT; stdcall;
    function RemoveSpellCheckerChanged(eventCookie: longword): HRESULT; stdcall;
    function GetOptionDescription(const optionId: pwidechar; out Value: IUnknown): HRESULT; stdcall;
    function ComprehensiveCheck(const Text: pwidechar; out Value: IEnumSpellingError): HRESULT; stdcall;
  end;

  ISpellCheckerFactory = interface(IUnknown)
    ['{8E018A9D-2415-4677-BF08-794EA61F94BB}']
    function GetSupportedLanguages(out Value: IEnumString): HRESULT; stdcall;
    function IsSupported(const languageTag: pwidechar; out Value: longbool): HRESULT; stdcall;
    function CreateSpellChecker(const languageTag: pwidechar; out Value: ISpellChecker): HRESULT; stdcall;
  end;

const
  CLSID_SpellCheckerFactory: TGUID =
    '{7AB36653-1796-484B-BDFA-E74F1DB7C1DC}';

// Checks the spelling of the given text using the Windows Spell Checking API
function CheckSpelling(const Text: widestring; const LanguageTag: string; out Errors: TSpellErrorArray): boolean;

// Normalize a language tag to BCP-47 format (e.g., "ru" -> "ru-RU", "ru-ru" -> "ru-RU")
function NormalizeLanguageTag(const Input: string): widestring;

// Check if a given BCP-47 language tag is supported by the Windows spell checker
function IsLanguageSupported(const LanguageTag: widestring): boolean;

// Converts a UTF-16 index into a byte index in the original UTF-8 string
function Utf16IndexToUtf8Byte(const Utf8Str: string; Utf16Index: integer): integer;

// Converts a UTF-16 index to a 1-based character (code point) index in the UTF-8 string
function Utf16ToUtf8CharIndex(const Utf8Str: string; Utf16Index: integer): integer;

{$ENDIF}

implementation

{$IFDEF WINDOWS}

function CheckSpelling(const Text: widestring; const LanguageTag: string; out Errors: TSpellErrorArray): boolean;
var
  factory: ISpellCheckerFactory = nil;
  checker: ISpellChecker = nil;
  errorEnum: IEnumSpellingError = nil;
  errorItem: ISpellingError = nil;
  suggEnum: IEnumString = nil;
  sugg: pwidechar = nil;
  startIdx: longword = 0;
  errLen: longword = 0;
  fetched: longword = 0;
  errorCount: integer = 0;
  errorIndex: integer = 0;
  hr: HRESULT;
  NormalizedTag: widestring = '';
  word: widestring;
begin
  Result := False;
  Errors := nil;

  if Text = '' then
    Exit;

  // Normalize and verify language
  NormalizedTag := NormalizeLanguageTag(LanguageTag);
  if NormalizedTag = '' then Exit;
  if not IsLanguageSupported(NormalizedTag) then Exit;

  hr := CoCreateInstance(CLSID_SpellCheckerFactory, nil, CLSCTX_INPROC_SERVER, ISpellCheckerFactory, factory);

  if Failed(hr) then
    Exit;

  hr := factory.CreateSpellChecker(pwidechar(NormalizedTag), checker);
  if Failed(hr) then
    Exit;

  hr := checker.Check(pwidechar(Text), errorEnum);
  if Failed(hr) or (errorEnum = nil) then
    Exit;

  while errorEnum.Next(errorItem) = S_OK do
  begin
    Inc(errorCount);
    errorItem := nil;
  end;

  if errorCount = 0 then
  begin
    Result := True;
    Exit;
  end;

  errorEnum := nil;

  hr := checker.Check(pwidechar(Text), errorEnum);
  if Failed(hr) or (errorEnum = nil) then
    Exit;

  SetLength(Errors, errorCount);

  errorIndex := 0;

  while (errorIndex < errorCount) and (errorEnum.Next(errorItem) = S_OK) do
  begin
    if errorItem = nil then
      Continue;

    hr := errorItem.GetStartIndex(startIdx);
    if Failed(hr) then
      Continue;

    hr := errorItem.GetLength(errLen);
    if Failed(hr) then
      Continue;

    Errors[errorIndex].Start := startIdx;
    Errors[errorIndex].Length := errLen;
    SetLength(Errors[errorIndex].Suggestions, 0);

    if errLen > 0 then
    begin
      word := Copy(Text, startIdx + 1, errLen);

      hr := checker.Suggest(pwidechar(word), suggEnum);

      if Succeeded(hr) and (suggEnum <> nil) then
      begin
        while suggEnum.Next(1, sugg, fetched) = S_OK do
        begin
          if fetched = 0 then
            Break;

          SetLength(
            Errors[errorIndex].Suggestions,
            Length(Errors[errorIndex].Suggestions) + 1
            );

          Errors[errorIndex].Suggestions[
            High(Errors[errorIndex].Suggestions)
            ] := sugg;

          CoTaskMemFree(sugg);
          sugg := nil;
        end;

        suggEnum := nil;
      end;
    end;

    errorItem := nil;
    Inc(errorIndex);
  end;

  SetLength(Errors, errorIndex);
  Result := True;
end;

function NormalizeLanguageTag(const Input: string): widestring;
var
  Part1, Part2: string;
  dashPos: integer;
begin
  Result := '';
  if Input = '' then Exit;

  dashPos := Pos('-', Input);
  if dashPos = 0 then
  begin
    // No dash, assume short code like "ru"
    if Length(Input) = 2 then
      Result := WideString(LowerCase(Input) + '-' + UpperCase(Input))
    else
      Result := WideString(Input);
  end
  else
  begin
    Part1 := Copy(Input, 1, dashPos - 1);
    Part2 := Copy(Input, dashPos + 1, Length(Input) - dashPos);
    Result := WideString(LowerCase(Part1) + '-' + UpperCase(Part2));
  end;
end;

function IsLanguageSupported(const LanguageTag: widestring): boolean;
var
  factory: ISpellCheckerFactory = nil;
  supported: longbool = False;
  hr: HRESULT = S_OK;
begin
  Result := False;

  hr := CoCreateInstance(CLSID_SpellCheckerFactory, nil, CLSCTX_INPROC_SERVER, ISpellCheckerFactory, factory);
  if Failed(hr) then Exit;

  hr := factory.IsSupported(pwidechar(LanguageTag), supported);
  if Succeeded(hr) and supported then
    Result := True;
end;

function Utf16IndexToUtf8Byte(const Utf8Str: string; Utf16Index: integer): integer;
var
  WideStr: widestring = '';
  i: integer = 0;
  BytePos: integer = 1;
begin
  Result := -1;
  WideStr := UTF8Decode(Utf8Str);
  if (Utf16Index < 0) or (Utf16Index > Length(WideStr)) then Exit;

  BytePos := 1;
  {$NOTES OFF}
  for i := 1 to Utf16Index do
    BytePos := BytePos + UTF8CodepointSize(@Utf8Str[BytePos]);
  {$NOTES ON}

  Result := BytePos;
end;

function Utf16ToUtf8CharIndex(const Utf8Str: string; Utf16Index: integer): integer;
var
  ByteIndex: integer;
begin
  ByteIndex := Utf16IndexToUtf8Byte(Utf8Str, Utf16Index);

  if ByteIndex < 0 then
    Exit(-1);

  // Utf16IndexToUtf8Byte returns a 1-based byte position
  Result := UTF8Length(Copy(Utf8Str, 1, ByteIndex - 1));
end;

{$ENDIF}

end.
