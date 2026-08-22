//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit WinSpellChecker;

{$mode objfpc}{$H+}
{$INTERFACES COM}

interface

{$IFDEF WINDOWS}
uses
Classes, SysUtils, ActiveX, ComObj, LazUTF8, RichSpellChecker;

type
  // Note: ErrorType is determined heuristically and may not be 100% reliable
  TSpellErrorType = (setSpelling, setComprehensiveSpelling);

  TSpellError = record
    Start: integer;
    Length: integer;
    Suggestions: array of widestring;
    ErrorType: TSpellErrorType;
  end;

  TSpellErrorArray = array of TSpellError;

  TSupportedLanguages = array of widestring;


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

// Converts a UTF-16 index into a byte index in the original UTF-8 string
function Utf16IndexToUtf8Byte(const Utf8Str: string; Utf16Index: integer): integer;

// Converts a UTF-16 index to a 1-based character (code point) index in the UTF-8 string
function Utf16ToUtf8CharIndex(const Utf8Str: string; Utf16Index: integer): integer;

// Checks spelling only (uses default options [scoSpelling])
function CheckSpelling(const Text: widestring; const LanguageTag: string; out Errors: TSpellErrorArray): boolean;

// Checks spelling and/or comprehensive spelling based on Options
function CheckSpelling(const Text: widestring; const LanguageTag: string; out Errors: TSpellErrorArray; Options: TSpellCheckOptions): boolean; overload;

// Normalize a language tag to BCP-47 format (e.g., "ru" -> "ru-RU", "ru-ru" -> "ru-RU")
function NormalizeLanguageTag(const Input: string): widestring;

// Check if a given BCP-47 language tag is supported by the Windows spell checker
function IsLanguageSupported(const LanguageTag: widestring): boolean;

// Returns a list of all available spell checker language tags in BCP-47 format
function GetSupportedSpellCheckerLanguages: TSupportedLanguages;

{$ENDIF}

implementation

uses localize;

  {$IFDEF WINDOWS}

var
  SpellCheckerLanguagesCache: TSupportedLanguages = nil;
  SpellCheckerLanguagesCached: boolean = False;

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

procedure ExtractErrorsFromEnum(const Text: widestring; checker: ISpellChecker; enum: IEnumSpellingError;
  out ErrorArray: TSpellErrorArray);
var
  errorItem: ISpellingError = nil;
  suggEnum: IEnumString = nil;
  sugg: pwidechar = nil;
  startIdx: longword = 0;
  errLen: longword = 0;
  fetched: longword = 0;
  hr: HRESULT;
  word: widestring;
  tempErrors: TSpellErrorArray = nil;
  currentIndex: integer = 0;
begin
  ErrorArray := nil;

  if enum = nil then Exit;

  while enum.Next(errorItem) = S_OK do
  begin
    if errorItem = nil then Continue;

    SetLength(tempErrors, Length(tempErrors) + 1);
    currentIndex := High(tempErrors);

    hr := errorItem.GetStartIndex(startIdx);
    if Failed(hr) then
    begin
      SetLength(tempErrors, Length(tempErrors) - 1);
      errorItem := nil;
      Continue;
    end;

    hr := errorItem.GetLength(errLen);
    if Failed(hr) then
    begin
      SetLength(tempErrors, Length(tempErrors) - 1);
      errorItem := nil;
      Continue;
    end;

    tempErrors[currentIndex].Start := startIdx;
    tempErrors[currentIndex].Length := errLen;
    tempErrors[currentIndex].ErrorType := setSpelling; // default, will be overwritten later
    SetLength(tempErrors[currentIndex].Suggestions, 0);

    if errLen > 0 then
    begin
      word := Copy(Text, startIdx + 1, errLen);

      hr := checker.Suggest(pwidechar(word), suggEnum);

      if Succeeded(hr) and (suggEnum <> nil) then
      begin
        while suggEnum.Next(1, sugg, fetched) = S_OK do
        begin
          if fetched = 0 then Break;

          SetLength(
            tempErrors[currentIndex].Suggestions,
            Length(tempErrors[currentIndex].Suggestions) + 1
            );

          tempErrors[currentIndex].Suggestions[
            High(tempErrors[currentIndex].Suggestions)
            ] := sugg;

          CoTaskMemFree(sugg);
          sugg := nil;
        end;

        suggEnum := nil;
      end;
    end;

    errorItem := nil;
  end;

  ErrorArray := tempErrors;
end;

function IsSameError(const E1, E2: TSpellError): boolean;
begin
  Result := (E1.Start = E2.Start) and (E1.Length = E2.Length);
end;

function CheckSpellingInternal(const Text: widestring; const LanguageTag: string; out Errors: TSpellErrorArray;
  Options: TSpellCheckOptions): boolean;
var
  factory: ISpellCheckerFactory = nil;
  checker: ISpellChecker = nil;
  spellingEnum: IEnumSpellingError = nil;
  comprehensiveEnum: IEnumSpellingError = nil;
  spellingErrors: TSpellErrorArray = nil;
  allErrors: TSpellErrorArray = nil;
  finalErrors: TSpellErrorArray = nil;
  i, j: integer;
  found: boolean;
  NormalizedTag: widestring = '';
  hr: HRESULT;
begin
  Result := False;
  Errors := nil;

  if Text = '' then Exit;
  if Options = [] then Exit;

  NormalizedTag := NormalizeLanguageTag(LanguageTag);
  if NormalizedTag = '' then Exit;
  if not IsLanguageSupported(NormalizedTag) then Exit;

  hr := CoCreateInstance(CLSID_SpellCheckerFactory, nil, CLSCTX_INPROC_SERVER, ISpellCheckerFactory, factory);
  if Failed(hr) then Exit;

  hr := factory.CreateSpellChecker(pwidechar(NormalizedTag), checker);
  if Failed(hr) then Exit;

  // Always get spelling errors (needed for both spelling and comprehensive spelling filtering)
  hr := checker.Check(pwidechar(Text), spellingEnum);
  if Failed(hr) or (spellingEnum = nil) then Exit;
  ExtractErrorsFromEnum(Text, checker, spellingEnum, spellingErrors);
  spellingEnum := nil;

  // If comprehensive spelling is requested, get comprehensive errors
  if scoComprehensiveSpelling in Options then
  begin
    hr := checker.ComprehensiveCheck(pwidechar(Text), comprehensiveEnum);
    if Failed(hr) or (comprehensiveEnum = nil) then Exit;
    ExtractErrorsFromEnum(Text, checker, comprehensiveEnum, allErrors);
    comprehensiveEnum := nil;
  end;

  // Build final error list based on options
  if (scoSpelling in Options) and (scoComprehensiveSpelling in Options) then
  begin
    SetLength(finalErrors, Length(allErrors));
    for i := 0 to High(allErrors) do
    begin
      finalErrors[i] := allErrors[i];
      found := False;
      for j := 0 to High(spellingErrors) do
      begin
        if IsSameError(allErrors[i], spellingErrors[j]) then
        begin
          found := True;
          Break;
        end;
      end;
      // Errors found only by ComprehensiveCheck are classified separately.
      if found then
        finalErrors[i].ErrorType := setSpelling
      else
        finalErrors[i].ErrorType := setComprehensiveSpelling; // heuristic: not in spelling => comprehensive spelling
    end;
  end
  else if scoSpelling in Options then
  begin
    SetLength(finalErrors, Length(spellingErrors));
    for i := 0 to High(spellingErrors) do
    begin
      finalErrors[i] := spellingErrors[i];
      finalErrors[i].ErrorType := setSpelling;
    end;
  end
  else if scoComprehensiveSpelling in Options then
  begin
    SetLength(finalErrors, 0);
    for i := 0 to High(allErrors) do
    begin
      found := False;
      for j := 0 to High(spellingErrors) do
      begin
        if IsSameError(allErrors[i], spellingErrors[j]) then
        begin
          found := True;
          Break;
        end;
      end;
      if not found then
      begin
        SetLength(finalErrors, Length(finalErrors) + 1);
        finalErrors[High(finalErrors)] := allErrors[i];
        finalErrors[High(finalErrors)].ErrorType := setComprehensiveSpelling;
      end;
    end;
  end;

  Errors := finalErrors;
  Result := True;
end;

function CheckSpelling(const Text: widestring; const LanguageTag: string; out Errors: TSpellErrorArray): boolean;
begin
  Result := CheckSpellingInternal(Text, LanguageTag, Errors, [scoSpelling]);
end;

function CheckSpelling(const Text: widestring; const LanguageTag: string; out Errors: TSpellErrorArray;
  Options: TSpellCheckOptions): boolean;
begin
  Result := CheckSpellingInternal(Text, LanguageTag, Errors, Options);
end;

// Returns the preferred BCP-47 tag for a short language code,
// used when the generic xx-XX form is not the most common variant.
function GetPreferredLanguageTag(const ShortCode: string): string;
begin
  Result := '';
  case LowerCase(ShortCode) of
    'en': Result := 'en-US';
    'pt': Result := 'pt-BR';
    'zh': Result := 'zh-CN';
    'ar': Result := 'ar-SA';
    'he': Result := 'he-IL';
    'el': Result := 'el-GR';
    'ja': Result := 'ja-JP';
    'ko': Result := 'ko-KR';
    'hi': Result := 'hi-IN';
    'vi': Result := 'vi-VN';
    'uk': Result := 'uk-UA';
    'cs': Result := 'cs-CZ';
    'da': Result := 'da-DK';
    'fi': Result := 'fi-FI';
    'nb': Result := 'nb-NO';
    'no': Result := 'nb-NO'; // map deprecated 'no' to Norwegian Bokmål
    'fa': Result := 'fa-IR';
    'ms': Result := 'ms-MY';
    'bn': Result := 'bn-BD';
    'ta': Result := 'ta-IN';
    'te': Result := 'te-IN';
    'mr': Result := 'mr-IN';
    'sw': Result := 'sw-TZ'; // or sw-KE depending on your preference
    'km': Result := 'km-KH';
    'lo': Result := 'lo-LA';
    'ne': Result := 'ne-NP';
    'si': Result := 'si-LK';
    'ka': Result := 'ka-GE';
    'hy': Result := 'hy-AM';
    'kk': Result := 'kk-KZ';
    'az': Result := 'az-Latn-AZ';
    'sq': Result := 'sq-AL';
  end;
end;

function NormalizeTwoLetterCode(const Value: string): string;
var
  Candidate: string = '';
  PreferredTag: string = '';
  Langs: TSupportedLanguages = nil;
  i: integer = 0;
  Prefix: string = '';
begin
  Result := '';

  // Try the constructed tag xx-XX first
  Candidate := LowerCase(Value) + '-' + UpperCase(Value);
  if IsLanguageSupported(WideString(Candidate)) then
  begin
    Result := Candidate;
    Exit;
  end;

  // Then try the preferred tag from the manual list
  PreferredTag := GetPreferredLanguageTag(Value);
  if (PreferredTag <> '') and IsLanguageSupported(WideString(PreferredTag)) then
  begin
    Result := PreferredTag;
    Exit;
  end;

  // If neither works, find the first available language with the same prefix
  Langs := GetSupportedSpellCheckerLanguages;
  Prefix := LowerCase(Value) + '-';
  for i := 0 to High(Langs) do
  begin
    if Pos(Prefix, LowerCase(string(Langs[i]))) = 1 then
    begin
      Result := string(Langs[i]);
      Break;
    end;
  end;

  // Last resort: return the constructed tag even if not supported
  if Result = '' then
    Result := Candidate;
end;

function NormalizeLanguageTag(const Input: string): widestring;
var
  Part1: string = '';
  Part2: string = '';
  dashPos: integer = 0;
const
  MAX_LANG_LENGTH = 15;
begin
  Result := '';
  if Input = '' then Exit;

  dashPos := Pos('-', Input);
  if dashPos = 0 then
  begin
    // No dash, assume short code like "en"
    if Length(Input) = 2 then
      Result := WideString(NormalizeTwoLetterCode(Input))
    else
      Result := WideString(NormalizeTwoLetterCode(Language));
  end
  else
  begin
    if Length(Input) > MAX_LANG_LENGTH then
      Result := WideString(NormalizeTwoLetterCode(Language))
    else
    begin
      // Already has a dash, just normalize case
      Part1 := Copy(Input, 1, dashPos - 1);
      Part2 := Copy(Input, dashPos + 1, Length(Input) - dashPos);
      Result := WideString(LowerCase(Part1) + '-' + UpperCase(Part2));
    end;
  end;
end;

function GetSupportedSpellCheckerLanguages: TSupportedLanguages;
var
  factory: ISpellCheckerFactory = nil;
  enum: IEnumString = nil;
  lang: pwidechar = nil;
  fetched: longword = 0;
  hr: HRESULT;
  langList: TSupportedLanguages = nil;
begin
  if SpellCheckerLanguagesCached then
    Exit(SpellCheckerLanguagesCache);

  Result := nil;

  hr := CoCreateInstance(CLSID_SpellCheckerFactory, nil, CLSCTX_INPROC_SERVER, ISpellCheckerFactory, factory);
  if Failed(hr) then Exit;

  hr := factory.GetSupportedLanguages(enum);
  if Failed(hr) or (enum = nil) then Exit;

  while enum.Next(1, lang, fetched) = S_OK do
  begin
    if fetched = 0 then Break;

    SetLength(langList, Length(langList) + 1);
    langList[High(langList)] := lang;

    CoTaskMemFree(lang);
    lang := nil;
  end;

  SpellCheckerLanguagesCache := langList;
  SpellCheckerLanguagesCached := True;
  Result := SpellCheckerLanguagesCache;
end;

function IsLanguageSupported(const LanguageTag: widestring): boolean;
var
  Langs: TSupportedLanguages = nil;
  i: integer = 0;
begin
  Result := False;
  if LanguageTag = '' then Exit;

  // Use cached list of supported languages to avoid repeated COM calls
  Langs := GetSupportedSpellCheckerLanguages;
  for i := 0 to High(Langs) do
  begin
    if WideCompareText(Langs[i], LanguageTag) = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

  {$ENDIF}

end.
